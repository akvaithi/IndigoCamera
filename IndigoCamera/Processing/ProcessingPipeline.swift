import Metal
import CoreMedia
import CoreVideo
import UIKit

/// Processing errors.
enum ProcessingError: Error, CustomStringConvertible {
    case noFrames
    case textureCreationFailed
    case alignmentFailed
    case mergeFailed
    case toneMapFailed

    var description: String {
        switch self {
        case .noFrames: return "No frames to process"
        case .textureCreationFailed: return "Failed to create Metal texture from frame"
        case .alignmentFailed: return "Frame alignment failed"
        case .mergeFailed: return "Frame merging failed"
        case .toneMapFailed: return "Tone mapping failed"
        }
    }
}

/// Orchestrates the full capture-to-output pipeline:
/// frames -> align -> merge -> tone map -> UIImage.
///
/// Memory strategy: processes one candidate frame at a time,
/// releasing textures immediately after use to minimize peak memory.
final class ProcessingPipeline {
    let metal: MetalContext
    private let texturePool: TexturePool
    private let aligner: FrameAligner
    private let merger: FrameMerger
    private let toneMapper: ToneMapper
    private var superResMerger: SuperResolutionMerger?
    private lazy var rawDemosacer = RAWDemosacer(metalContext: metal, texturePool: texturePool)

    init(metalContext: MetalContext) {
        self.metal = metalContext
        self.texturePool = TexturePool(device: metalContext.device)
        self.aligner = FrameAligner(metalContext: metalContext, texturePool: texturePool)
        self.merger = FrameMerger(metalContext: metalContext, texturePool: texturePool)
        self.toneMapper = ToneMapper(metalContext: metalContext, texturePool: texturePool)
    }

    /// Process a burst of CMSampleBuffers into a single merged, tone-mapped UIImage.
    ///
    /// - Parameters:
    ///   - frames: Array of CMSampleBuffers (oldest first, reference = last)
    ///   - settings: Current capture settings
    ///   - progress: Callback with progress value (0.0 to 1.0)
    /// - Returns: The final processed UIImage
    func process(frames: [CMSampleBuffer],
                 settings: CaptureSettings,
                 progress: @escaping (Float) -> Void) throws -> UIImage {

        guard !frames.isEmpty else {
            throw ProcessingError.noFrames
        }

        // Single frame: skip alignment and merging
        if frames.count == 1 {
            return try processSingleFrame(frames[0], settings: settings)
        }

        // Multi-frame: align and merge
        let totalFrames = Float(frames.count)

        // 1. Convert reference frame (last in array) to texture
        guard let referenceBuffer = frames.last,
              let refPixelBuffer = CMSampleBufferGetImageBuffer(referenceBuffer),
              let referenceTex = refPixelBuffer.toMTLTexture(
                  textureCache: metal.textureCache
              ) else {
            throw ProcessingError.textureCreationFailed
        }

        // 2. Create accumulators
        guard let (accumColor, accumWeight) = merger.createAccumulators(
            width: referenceTex.width, height: referenceTex.height
        ) else {
            throw ProcessingError.mergeFailed
        }

        // 3. Add reference frame with higher weight (no alignment needed)
        merger.accumulate(frame: referenceTex, reference: referenceTex,
                          accumColor: accumColor, accumWeight: accumWeight,
                          sigma: settings.mergeSigma, baseWeight: 2.0)
        progress(1.0 / totalFrames)

        // 4. Process each candidate frame one at a time
        for (index, frameBuffer) in frames.dropLast().enumerated() {
            autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(frameBuffer),
                      let candidateTex = pixelBuffer.toMTLTexture(
                          textureCache: metal.textureCache
                      ) else {
                    Log.processing.warning("Skipping frame \(index): texture creation failed")
                    return
                }

                // Align candidate to reference
                if let aligned = aligner.align(candidate: candidateTex, to: referenceTex) {
                    // Merge aligned frame into accumulators
                    merger.accumulate(frame: aligned.alignedTexture,
                                      reference: referenceTex,
                                      accumColor: accumColor, accumWeight: accumWeight,
                                      sigma: settings.mergeSigma, baseWeight: 1.0)
                    texturePool.release(aligned.alignedTexture)
                } else {
                    // Alignment failed - merge unaligned (better than nothing)
                    merger.accumulate(frame: candidateTex, reference: referenceTex,
                                      accumColor: accumColor, accumWeight: accumWeight,
                                      sigma: settings.mergeSigma, baseWeight: 0.5)
                    Log.processing.warning("Alignment failed for frame \(index), using unaligned")
                }
            }

            progress(Float(index + 2) / totalFrames)
        }

        // 5. Normalize the accumulated result
        guard let merged = merger.normalize(accumColor: accumColor, accumWeight: accumWeight) else {
            throw ProcessingError.mergeFailed
        }

        // 6. Tone map
        guard let result = toneMapper.process(mergedTexture: merged, settings: settings) else {
            throw ProcessingError.toneMapFailed
        }

        // 7. Cleanup
        texturePool.release(accumColor)
        texturePool.release(accumWeight)
        texturePool.release(merged)

        Log.processing.info("Processing complete: \(frames.count) frames merged")
        return result
    }

    /// Process a single frame (no alignment or merging needed).
    private func processSingleFrame(_ frame: CMSampleBuffer,
                                     settings: CaptureSettings) throws -> UIImage {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame),
              let texture = pixelBuffer.toMTLTexture(textureCache: metal.textureCache) else {
            throw ProcessingError.textureCreationFailed
        }

        guard let result = toneMapper.process(mergedTexture: texture, settings: settings) else {
            throw ProcessingError.toneMapFailed
        }

        return result
    }

    // MARK: - Frame Preparation

    /// Convert CMSampleBuffers to standalone Metal textures.
    /// Deep-copies pixel data so the original CVPixelBuffers can be released
    /// without invalidating the textures during processing.
    func prepareFrames(_ frames: [CMSampleBuffer]) throws -> [MTLTexture] {
        var textures: [MTLTexture] = []
        textures.reserveCapacity(frames.count)

        for (index, frame) in frames.enumerated() {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(frame) else {
                Log.processing.warning("Frame \(index): no pixel buffer")
                continue
            }

            if index == 0 {
                Log.processing.info("Video frame dimensions: \(pixelBuffer.width)x\(pixelBuffer.height)")
            }

            guard let cvTexture = pixelBuffer.toMTLTexture(textureCache: metal.textureCache) else {
                Log.processing.warning("Frame \(index): texture creation failed")
                continue
            }

            guard let standalone = copyToStandaloneTexture(cvTexture) else {
                Log.processing.warning("Frame \(index): copy to standalone texture failed")
                continue
            }

            textures.append(standalone)
        }

        guard !textures.isEmpty else {
            throw ProcessingError.textureCreationFailed
        }

        Log.processing.info("Prepared \(textures.count) standalone textures (\(textures[0].width)x\(textures[0].height))")
        return textures
    }

    // MARK: - RAW Demosaic

    /// Demosaic DNG data into linear-light Metal textures.
    /// Each DNG is removed from the array after demosaicing to free memory immediately.
    /// Optional evOffsets: per-frame EV compensation for HDR bracket normalization.
    func demosaicRAWFrames(_ dngFrames: inout [Data],
                           evOffsets: [Float]? = nil,
                           progress: @escaping (Float) -> Void) throws -> [MTLTexture] {
        var textures: [MTLTexture] = []
        let total = dngFrames.count
        textures.reserveCapacity(total)

        var frameIndex = 0
        while !dngFrames.isEmpty {
            let dngData = dngFrames.removeFirst()
            let evComp = evOffsets?[frameIndex] ?? 0
            let texture = try rawDemosacer.demosaic(dngData, evCompensation: evComp)
            textures.append(texture)
            frameIndex += 1
            progress(Float(textures.count) / Float(total))
        }

        guard !textures.isEmpty else {
            throw ProcessingError.textureCreationFailed
        }

        Log.processing.info("Demosaiced \(textures.count) RAW frames (\(textures[0].width)x\(textures[0].height))")
        return textures
    }

    /// Deep-copy a CVPixelBuffer-backed texture to a standalone GPU texture.
    private func copyToStandaloneTexture(_ source: MTLTexture) -> MTLTexture? {
        guard let dest = texturePool.acquire(
            width: source.width, height: source.height,
            pixelFormat: source.pixelFormat
        ) else { return nil }

        guard let commandBuffer = metal.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return nil }

        blitEncoder.copy(
            from: source, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
            to: dest, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return dest
    }

    // MARK: - Stack Processing (Texture Input)

    /// Process standalone textures into a merged linear rgba16Float texture (no tone mapping).
    /// For DNG/TIFF output -- preserves linear light data for Lightroom editing.
    func processToTexture(textures: [MTLTexture],
                          settings: CaptureSettings,
                          progress: @escaping (Float) -> Void) throws -> MTLTexture {
        guard !textures.isEmpty else {
            throw ProcessingError.noFrames
        }

        if textures.count == 1 {
            progress(1.0)
            return textures[0]
        }

        let totalFrames = Float(textures.count)
        let referenceTex = textures.last!

        Log.processing.info("Stack: merging \(textures.count) frames at \(referenceTex.width)x\(referenceTex.height)")

        guard let (accumColor, accumWeight) = merger.createAccumulators(
            width: referenceTex.width, height: referenceTex.height
        ) else {
            throw ProcessingError.mergeFailed
        }

        merger.accumulate(frame: referenceTex, reference: referenceTex,
                          accumColor: accumColor, accumWeight: accumWeight,
                          sigma: settings.mergeSigma, baseWeight: 2.0)
        progress(1.0 / totalFrames)

        for (index, candidateTex) in textures.dropLast().enumerated() {
            autoreleasepool {
                if let aligned = aligner.align(candidate: candidateTex, to: referenceTex) {
                    merger.accumulate(frame: aligned.alignedTexture,
                                      reference: referenceTex,
                                      accumColor: accumColor, accumWeight: accumWeight,
                                      sigma: settings.mergeSigma, baseWeight: 1.0)
                    texturePool.release(aligned.alignedTexture)
                } else {
                    merger.accumulate(frame: candidateTex, reference: referenceTex,
                                      accumColor: accumColor, accumWeight: accumWeight,
                                      sigma: settings.mergeSigma, baseWeight: 0.5)
                }
            }
            progress(Float(index + 2) / totalFrames)
        }

        guard let merged = merger.normalize(accumColor: accumColor, accumWeight: accumWeight) else {
            throw ProcessingError.mergeFailed
        }

        texturePool.release(accumColor)
        texturePool.release(accumWeight)

        Log.processing.info("Stack complete: \(referenceTex.width)x\(referenceTex.height) merged")
        return merged
    }

    // MARK: - HDR Merge (Texture Input)

    /// Merge EV-compensated bracketed-exposure textures using standard Cauchy merge.
    /// All textures must already be normalized to the same apparent brightness
    /// (via EV compensation during demosaicing). The merge combines the best
    /// signal-to-noise ratio from each physical exposure:
    /// - Short exposures contribute clean highlights
    /// - Long exposures contribute clean shadows
    func processHDR(textures: [MTLTexture],
                    settings: CaptureSettings,
                    progress: @escaping (Float) -> Void) throws -> MTLTexture {
        guard !textures.isEmpty else {
            throw ProcessingError.noFrames
        }

        if textures.count == 1 {
            progress(1.0)
            return textures[0]
        }

        let totalFrames = Float(textures.count)
        // Use middle exposure (0EV baseline) as reference for alignment
        let refIndex = textures.count / 2
        let referenceTex = textures[refIndex]

        Log.processing.info("HDR: merging \(textures.count) EV-compensated frames at \(referenceTex.width)x\(referenceTex.height)")

        guard let (accumColor, accumWeight) = merger.createAccumulators(
            width: referenceTex.width, height: referenceTex.height
        ) else {
            throw ProcessingError.mergeFailed
        }

        // Add reference frame with higher weight
        merger.accumulate(frame: referenceTex, reference: referenceTex,
                          accumColor: accumColor, accumWeight: accumWeight,
                          sigma: settings.mergeSigma, baseWeight: 2.0)
        progress(1.0 / totalFrames)

        // Align and merge each other frame using standard Cauchy weights.
        // Since all frames are EV-compensated to the same brightness, alignment
        // works correctly and Cauchy weights properly handle motion outliers.
        for (index, candidateTex) in textures.enumerated() {
            guard index != refIndex else { continue }
            autoreleasepool {
                if let aligned = aligner.align(candidate: candidateTex, to: referenceTex) {
                    merger.accumulate(frame: aligned.alignedTexture,
                                      reference: referenceTex,
                                      accumColor: accumColor, accumWeight: accumWeight,
                                      sigma: settings.mergeSigma, baseWeight: 1.0)
                    texturePool.release(aligned.alignedTexture)
                } else {
                    merger.accumulate(frame: candidateTex, reference: referenceTex,
                                      accumColor: accumColor, accumWeight: accumWeight,
                                      sigma: settings.mergeSigma, baseWeight: 0.5)
                    Log.processing.warning("HDR: alignment failed for frame \(index), using unaligned")
                }
            }
            progress(Float(index + 1) / totalFrames)
        }

        guard let merged = merger.normalize(accumColor: accumColor, accumWeight: accumWeight) else {
            throw ProcessingError.mergeFailed
        }

        texturePool.release(accumColor)
        texturePool.release(accumWeight)

        Log.processing.info("HDR fusion complete: \(referenceTex.width)x\(referenceTex.height)")
        return merged
    }

    // MARK: - Super-Resolution Processing (Texture Input)

    /// Process textures using super-resolution (sub-pixel alignment on upscaled grid).
    /// Scale is passed explicitly since CaptureSettings.captureMode may not be synced with the UI mode.
    func processSuperRes(textures: [MTLTexture],
                         scale: Float,
                         settings: CaptureSettings,
                         progress: @escaping (Float) -> Void) throws -> MTLTexture {
        if superResMerger == nil {
            superResMerger = SuperResolutionMerger(
                metalContext: metal, texturePool: texturePool, aligner: aligner
            )
        }
        return try superResMerger!.process(
            textures: textures,
            scale: scale,
            settings: settings,
            progress: progress
        )
    }

    // MARK: - Streaming HDR (One Frame at a Time)

    /// Stream-process DNG frames for HDR: demosaic one frame at a time, align, merge, release.
    /// Peak memory: ~1 input texture + accumulators + aligned texture (~340MB for 4032x3024).
    func streamHDR(dngFrames: inout [Data],
                   evOffsets: [Float],
                   settings: CaptureSettings,
                   progress: @escaping (Float) -> Void) throws -> MTLTexture {
        let total = dngFrames.count
        guard total >= 2 else { throw ProcessingError.noFrames }

        // Demosaic the middle frame first as reference (0EV baseline).
        let refIndex = total / 2
        let refData = dngFrames[refIndex]
        let refEV = evOffsets[refIndex]
        let referenceTex = try rawDemosacer.demosaic(refData, evCompensation: refEV)

        Log.processing.info("HDR stream: ref frame \(refIndex), \(referenceTex.width)x\(referenceTex.height)")

        // Create accumulators at native resolution
        guard let (accumColor, accumWeight) = merger.createAccumulators(
            width: referenceTex.width, height: referenceTex.height
        ) else {
            texturePool.release(referenceTex)
            throw ProcessingError.mergeFailed
        }

        // Add reference frame with higher weight (no alignment needed)
        merger.accumulate(frame: referenceTex, reference: referenceTex,
                          accumColor: accumColor, accumWeight: accumWeight,
                          sigma: settings.mergeSigma, baseWeight: 2.0)
        progress(1.0 / Float(total))

        // Process each other frame one at a time: demosaic -> align -> merge -> release
        for i in 0..<total {
            guard i != refIndex else { continue }
            autoreleasepool {
                do {
                    let dngData = dngFrames[i]
                    let evComp = evOffsets[i]
                    let candidateTex = try rawDemosacer.demosaic(dngData, evCompensation: evComp)

                    if let aligned = aligner.align(candidate: candidateTex, to: referenceTex) {
                        merger.accumulate(frame: aligned.alignedTexture,
                                          reference: referenceTex,
                                          accumColor: accumColor, accumWeight: accumWeight,
                                          sigma: settings.mergeSigma, baseWeight: 1.0)
                        texturePool.release(aligned.alignedTexture)
                    } else {
                        merger.accumulate(frame: candidateTex, reference: referenceTex,
                                          accumColor: accumColor, accumWeight: accumWeight,
                                          sigma: settings.mergeSigma, baseWeight: 0.5)
                        Log.processing.warning("HDR stream: alignment failed for frame \(i), using unaligned")
                    }

                    texturePool.release(candidateTex)
                } catch {
                    Log.processing.warning("HDR stream: failed to demosaic frame \(i): \(error)")
                }
            }
            progress(Float(i + 1) / Float(total))
        }

        // Release reference texture before normalization to reduce peak memory
        texturePool.release(referenceTex)

        // Free DNG data to release CPU memory
        dngFrames.removeAll()

        guard let merged = merger.normalize(accumColor: accumColor, accumWeight: accumWeight) else {
            texturePool.release(accumColor)
            texturePool.release(accumWeight)
            throw ProcessingError.mergeFailed
        }

        texturePool.release(accumColor)
        texturePool.release(accumWeight)

        Log.processing.info("HDR stream complete: \(merged.width)x\(merged.height)")
        return merged
    }

    // MARK: - Streaming Super-Resolution (One Frame at a Time)

    /// Stream-process DNG frames for super-resolution: demosaic one frame at a time,
    /// align with sub-pixel precision, warp+upsample to high-res grid, merge, release.
    /// Peak memory: ~1 input texture + high-res accumulators + upsampled ref (~590MB for 1.5x).
    func streamSuperRes(dngFrames: inout [Data],
                        scale: Float,
                        settings: CaptureSettings,
                        progress: @escaping (Float) -> Void) throws -> MTLTexture {
        if superResMerger == nil {
            superResMerger = SuperResolutionMerger(
                metalContext: metal, texturePool: texturePool, aligner: aligner
            )
        }
        return try superResMerger!.processStreaming(
            dngFrames: &dngFrames,
            scale: scale,
            settings: settings,
            demosacer: rawDemosacer,
            progress: progress
        )
    }

    /// Release a texture back to the pool.
    func releaseTexture(_ texture: MTLTexture) {
        texturePool.release(texture)
    }

    /// Release all pooled textures (call on memory warning).
    func purge() {
        texturePool.purge()
    }
}
