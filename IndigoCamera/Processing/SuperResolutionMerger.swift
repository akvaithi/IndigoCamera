import Metal

/// Performs super-resolution by accumulating multi-frame data onto an upscaled grid.
/// Each frame is aligned with sub-pixel precision, then warped+upsampled to the high-res grid.
final class SuperResolutionMerger {
    private let metalContext: MetalContext
    private let texturePool: TexturePool
    private let aligner: FrameAligner

    init(metalContext: MetalContext, texturePool: TexturePool, aligner: FrameAligner) {
        self.metalContext = metalContext
        self.texturePool = texturePool
        self.aligner = aligner
    }

    /// Process standalone textures into a high-resolution merged texture.
    func process(textures: [MTLTexture],
                 scale: Float,
                 settings: CaptureSettings,
                 progress: @escaping (Float) -> Void) throws -> MTLTexture {
        guard textures.count >= 2 else { throw ProcessingError.noFrames }

        let refTex = textures.last!
        let outWidth = Int(Float(refTex.width) * scale)
        let outHeight = Int(Float(refTex.height) * scale)
        let invScale = 1.0 / scale

        Log.processing.info("Super-res: \(refTex.width)x\(refTex.height) -> \(outWidth)x\(outHeight) (\(scale)x)")

        // 1. Upsample reference to high-res grid
        guard let refUpsampled = upsampleTexture(refTex, width: outWidth, height: outHeight,
                                                  dx: 0, dy: 0, invScale: invScale) else {
            throw ProcessingError.textureCreationFailed
        }

        // 2. Create high-res accumulators
        guard let accumColor = texturePool.acquire(width: outWidth, height: outHeight, pixelFormat: .rgba16Float),
              let accumWeight = texturePool.acquire(width: outWidth, height: outHeight, pixelFormat: .r16Float) else {
            throw ProcessingError.mergeFailed
        }
        clearTexture(accumColor)
        clearTexture(accumWeight)

        // 3. Accumulate reference frame (dx=0, dy=0)
        accumulateFrame(frame: refTex, reference: refUpsampled,
                        accumColor: accumColor, accumWeight: accumWeight,
                        dx: 0, dy: 0, invScale: invScale,
                        sigma: settings.mergeSigma, baseWeight: 2.0)
        progress(1.0 / Float(textures.count))

        // 4. Align and accumulate each candidate frame with sub-pixel offsets.
        for (index, candidateTex) in textures.dropLast().enumerated() {
            autoreleasepool {
                if let alignment = aligner.align(candidate: candidateTex, to: refTex) {
                    Log.processing.debug("Super-res frame \(index): offset dx=\(alignment.dx), dy=\(alignment.dy)")
                    accumulateFrame(frame: candidateTex, reference: refUpsampled,
                                    accumColor: accumColor, accumWeight: accumWeight,
                                    dx: alignment.dx, dy: alignment.dy, invScale: invScale,
                                    sigma: settings.mergeSigma, baseWeight: 1.0)
                    texturePool.release(alignment.alignedTexture)
                } else {
                    Log.processing.warning("Super-res frame \(index): alignment failed, skipping")
                }
            }
            progress(Float(index + 2) / Float(textures.count))
        }

        // 5. Normalize
        guard let result = normalize(accumColor: accumColor, accumWeight: accumWeight) else {
            throw ProcessingError.mergeFailed
        }

        texturePool.release(accumColor)
        texturePool.release(accumWeight)
        texturePool.release(refUpsampled)

        Log.processing.info("Super-res complete: \(outWidth)x\(outHeight)")
        return result
    }

    /// Stream-process DNG frames: demosaic one at a time, align, warp+upsample, merge, release.
    /// Peak memory: reference texture + upsampled reference + high-res accumulators + 1 candidate.
    func processStreaming(dngFrames: inout [Data],
                          scale: Float,
                          settings: CaptureSettings,
                          demosacer: RAWDemosacer,
                          progress: @escaping (Float) -> Void) throws -> MTLTexture {
        let total = dngFrames.count
        guard total >= 2 else { throw ProcessingError.noFrames }

        // Demosaic the last frame as reference (consistent with texture-based processing)
        let refData = dngFrames.last!
        let referenceTex = try demosacer.demosaic(refData)

        let outWidth = Int(Float(referenceTex.width) * scale)
        let outHeight = Int(Float(referenceTex.height) * scale)
        let invScale = 1.0 / scale

        Log.processing.info("Super-res stream: \(referenceTex.width)x\(referenceTex.height) -> \(outWidth)x\(outHeight) (\(scale)x)")

        // Upsample reference to high-res grid
        guard let refUpsampled = upsampleTexture(referenceTex, width: outWidth, height: outHeight,
                                                  dx: 0, dy: 0, invScale: invScale) else {
            texturePool.release(referenceTex)
            throw ProcessingError.textureCreationFailed
        }

        // Create high-res accumulators
        guard let accumColor = texturePool.acquire(width: outWidth, height: outHeight, pixelFormat: .rgba16Float),
              let accumWeight = texturePool.acquire(width: outWidth, height: outHeight, pixelFormat: .r16Float) else {
            texturePool.release(referenceTex)
            texturePool.release(refUpsampled)
            throw ProcessingError.mergeFailed
        }
        clearTexture(accumColor)
        clearTexture(accumWeight)

        // Accumulate reference frame
        accumulateFrame(frame: referenceTex, reference: refUpsampled,
                        accumColor: accumColor, accumWeight: accumWeight,
                        dx: 0, dy: 0, invScale: invScale,
                        sigma: settings.mergeSigma, baseWeight: 2.0)
        progress(1.0 / Float(total))

        // Stream each candidate: demosaic -> align -> warp+upsample -> merge -> release
        for i in 0..<(total - 1) {
            autoreleasepool {
                do {
                    let dngData = dngFrames[i]
                    let candidateTex = try demosacer.demosaic(dngData)

                    if let alignment = aligner.align(candidate: candidateTex, to: referenceTex) {
                        Log.processing.debug("Super-res stream frame \(i): offset dx=\(alignment.dx), dy=\(alignment.dy)")
                        accumulateFrame(frame: candidateTex, reference: refUpsampled,
                                        accumColor: accumColor, accumWeight: accumWeight,
                                        dx: alignment.dx, dy: alignment.dy, invScale: invScale,
                                        sigma: settings.mergeSigma, baseWeight: 1.0)
                        texturePool.release(alignment.alignedTexture)
                    } else {
                        Log.processing.warning("Super-res stream frame \(i): alignment failed, skipping")
                    }

                    texturePool.release(candidateTex)
                } catch {
                    Log.processing.warning("Super-res stream frame \(i): demosaic failed: \(error)")
                }
            }
            progress(Float(i + 2) / Float(total))
        }

        // Release reference textures before normalize to reduce peak memory
        texturePool.release(referenceTex)

        // Free DNG data to release CPU memory
        dngFrames.removeAll()

        // Normalize
        guard let result = normalize(accumColor: accumColor, accumWeight: accumWeight) else {
            texturePool.release(accumColor)
            texturePool.release(accumWeight)
            texturePool.release(refUpsampled)
            throw ProcessingError.mergeFailed
        }

        texturePool.release(accumColor)
        texturePool.release(accumWeight)
        texturePool.release(refUpsampled)

        Log.processing.info("Super-res stream complete: \(outWidth)x\(outHeight)")
        return result
    }

    // MARK: - GPU Operations

    /// Upsample a source texture to high-res grid with offset.
    private func upsampleTexture(_ input: MTLTexture, width: Int, height: Int,
                                  dx: Float, dy: Float, invScale: Float) -> MTLTexture? {
        guard let output = texturePool.acquire(width: width, height: height, pixelFormat: .rgba16Float) else {
            return nil
        }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        var params = SuperResParams(dx: dx, dy: dy, invScale: invScale)
        encoder.setComputePipelineState(metalContext.superResWarpPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<SuperResParams>.size, index: 0)

        let (tg, tpg) = metalContext.threadgroupSize(for: metalContext.superResWarpPipeline,
                                                      width: width, height: height)
        encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }

    /// Warp+upsample a candidate, compute weights, and accumulate -- all in one command buffer.
    private func accumulateFrame(frame: MTLTexture, reference: MTLTexture,
                                  accumColor: MTLTexture, accumWeight: MTLTexture,
                                  dx: Float, dy: Float, invScale: Float,
                                  sigma: Float, baseWeight: Float) {
        let outW = accumColor.width
        let outH = accumColor.height

        guard let warped = texturePool.acquire(width: outW, height: outH, pixelFormat: .rgba16Float),
              let weights = texturePool.acquire(width: outW, height: outH, pixelFormat: .r16Float) else { return }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else { return }

        // Pass 1: Warp + upsample candidate to high-res grid
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var params = SuperResParams(dx: dx, dy: dy, invScale: invScale)
            encoder.setComputePipelineState(metalContext.superResWarpPipeline)
            encoder.setTexture(frame, index: 0)
            encoder.setTexture(warped, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<SuperResParams>.size, index: 0)
            let (tg, tpg) = metalContext.threadgroupSize(for: metalContext.superResWarpPipeline,
                                                          width: outW, height: outH)
            encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        // Pass 2: Compute Cauchy weights vs upsampled reference
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var params = MergeParams(sigma: sigma, frameWeight: baseWeight)
            encoder.setComputePipelineState(metalContext.superResWeightPipeline)
            encoder.setTexture(reference, index: 0)
            encoder.setTexture(warped, index: 1)
            encoder.setTexture(weights, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<MergeParams>.size, index: 0)
            let (tg, tpg) = metalContext.threadgroupSize(for: metalContext.superResWeightPipeline,
                                                          width: outW, height: outH)
            encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        // Pass 3: Accumulate (reuses existing accumulate_kernel)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(metalContext.accumulatePipeline)
            encoder.setTexture(warped, index: 0)
            encoder.setTexture(weights, index: 1)
            encoder.setTexture(accumColor, index: 2)
            encoder.setTexture(accumWeight, index: 3)
            let (tg, tpg) = metalContext.threadgroupSize(for: metalContext.accumulatePipeline,
                                                          width: outW, height: outH)
            encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        texturePool.release(warped)
        texturePool.release(weights)
    }

    /// Normalize accumulators to produce final merged texture.
    private func normalize(accumColor: MTLTexture, accumWeight: MTLTexture) -> MTLTexture? {
        guard let output = texturePool.acquire(width: accumColor.width, height: accumColor.height,
                                                pixelFormat: .rgba16Float) else { return nil }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(metalContext.normalizePipeline)
        encoder.setTexture(accumColor, index: 0)
        encoder.setTexture(accumWeight, index: 1)
        encoder.setTexture(output, index: 2)

        let (tg, tpg) = metalContext.threadgroupSize(for: metalContext.normalizePipeline,
                                                      width: output.width, height: output.height)
        encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }

    /// Clear a texture to zero.
    private func clearTexture(_ texture: MTLTexture) {
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(metalContext.clearPipeline)
        encoder.setTexture(texture, index: 0)

        let (tg, tpg) = metalContext.threadgroupSize(for: metalContext.clearPipeline,
                                                      width: texture.width, height: texture.height)
        encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
