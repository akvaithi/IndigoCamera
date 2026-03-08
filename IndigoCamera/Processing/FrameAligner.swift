import Metal
import CoreVideo

/// Aligns burst frames to a reference frame using coarse-to-fine pyramid SAD matching.
/// Uses global translation alignment (dx, dy) - sufficient for handheld burst captures
/// where inter-frame motion is small.
final class FrameAligner {
    private let metalContext: MetalContext
    private let texturePool: TexturePool
    private let pyramidLevels = 4  // 4032->2016->1008->504

    struct AlignmentResult {
        let dx: Float
        let dy: Float
        let alignedTexture: MTLTexture
    }

    init(metalContext: MetalContext, texturePool: TexturePool) {
        self.metalContext = metalContext
        self.texturePool = texturePool
    }

    /// Align `candidate` to `reference`. Returns the alignment offset and warped texture.
    func align(candidate: MTLTexture,
               to reference: MTLTexture) -> AlignmentResult? {

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            Log.processing.error("Failed to create command buffer for alignment")
            return nil
        }

        // 1. Convert both to grayscale
        guard let refGray = convertToGrayscale(reference, commandBuffer: commandBuffer),
              let candGray = convertToGrayscale(candidate, commandBuffer: commandBuffer) else {
            return nil
        }

        // 2. Build pyramids (each level is half the resolution)
        let refPyramid = buildPyramid(refGray, commandBuffer: commandBuffer)
        let candPyramid = buildPyramid(candGray, commandBuffer: commandBuffer)

        // Commit grayscale + pyramid computation and wait
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // 3. Coarse-to-fine alignment
        var dx: Int = 0
        var dy: Int = 0
        var lastSadBuffer: MTLBuffer?
        var lastSearchRadius: Int = 0

        for level in stride(from: pyramidLevels - 1, through: 0, by: -1) {
            let searchRadius = (level == pyramidLevels - 1) ? 32 : 2
            let sampleStep = max(1, min(refPyramid[level].width, refPyramid[level].height) / 64)

            if let result = searchBestOffset(
                reference: refPyramid[level],
                candidate: candPyramid[level],
                baseDx: dx,
                baseDy: dy,
                searchRadius: searchRadius,
                sampleStep: sampleStep
            ) {
                dx = result.dx
                dy = result.dy
                if level == 0 {
                    lastSadBuffer = result.sadBuffer
                    lastSearchRadius = searchRadius
                }
            }

            // Scale up for next finer level (except at level 0)
            if level > 0 {
                dx *= 2
                dy *= 2
            }
        }

        // Sub-pixel refinement at level 0
        var finalDx = Float(dx)
        var finalDy = Float(dy)
        if let sadBuffer = lastSadBuffer {
            let searchDiam = 2 * lastSearchRadius + 1
            let sadPointer = sadBuffer.contents().bindMemory(to: Float.self, capacity: searchDiam * searchDiam)
            let (subX, subY) = subPixelRefine(sadPointer: sadPointer, searchDiam: searchDiam)
            finalDx = Float(dx) + subX
            finalDy = Float(dy) + subY
        }

        // 4. Apply final warp at full resolution with sub-pixel offset
        guard let aligned = warpTexture(candidate, dx: finalDx, dy: finalDy) else {
            return nil
        }

        // 5. Release intermediate textures
        // Note: pyramid[0] IS the grayscale texture, so skip it to avoid double-release
        texturePool.release(refGray)
        texturePool.release(candGray)
        for tex in refPyramid.dropFirst() { texturePool.release(tex) }
        for tex in candPyramid.dropFirst() { texturePool.release(tex) }

        Log.processing.debug("Aligned frame: dx=\(finalDx), dy=\(finalDy)")
        return AlignmentResult(dx: finalDx, dy: finalDy, alignedTexture: aligned)
    }

    // MARK: - Grayscale Conversion

    private func convertToGrayscale(_ input: MTLTexture,
                                     commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let output = texturePool.acquire(width: input.width, height: input.height,
                                                pixelFormat: .r16Float) else { return nil }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(metalContext.grayscalePipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)

        let (threadgroups, threadsPerGroup) = metalContext.threadgroupSize(
            for: metalContext.grayscalePipeline, width: output.width, height: output.height
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        return output
    }

    // MARK: - Pyramid Building

    private func buildPyramid(_ input: MTLTexture,
                               commandBuffer: MTLCommandBuffer) -> [MTLTexture] {
        var pyramid = [input]

        for _ in 1..<pyramidLevels {
            let prev = pyramid.last!
            let halfW = max(1, prev.width / 2)
            let halfH = max(1, prev.height / 2)

            guard let downsampled = texturePool.acquire(width: halfW, height: halfH,
                                                         pixelFormat: .r16Float) else { break }
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { break }

            encoder.setComputePipelineState(metalContext.downsamplePipeline)
            encoder.setTexture(prev, index: 0)
            encoder.setTexture(downsampled, index: 1)

            let (threadgroups, threadsPerGroup) = metalContext.threadgroupSize(
                for: metalContext.downsamplePipeline, width: halfW, height: halfH
            )
            encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()

            pyramid.append(downsampled)
        }

        return pyramid
    }

    // MARK: - SAD Search

    private struct SADResult {
        let dx: Int
        let dy: Int
        let gridX: Int      // Best X index in the search grid
        let gridY: Int      // Best Y index in the search grid
        let sadBuffer: MTLBuffer
    }

    private func searchBestOffset(reference: MTLTexture,
                                   candidate: MTLTexture,
                                   baseDx: Int, baseDy: Int,
                                   searchRadius: Int,
                                   sampleStep: Int) -> SADResult? {
        let searchDiam = 2 * searchRadius + 1
        let sadBufferSize = searchDiam * searchDiam * MemoryLayout<Float>.size

        guard let sadBuffer = metalContext.device.makeBuffer(length: sadBufferSize,
                                                              options: .storageModeShared) else {
            return nil
        }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }

        var params = AlignmentParams(
            searchRadius: Int32(searchRadius),
            baseDx: Int32(baseDx),
            baseDy: Int32(baseDy),
            sampleStep: Int32(sampleStep)
        )

        encoder.setComputePipelineState(metalContext.sadPipeline)
        encoder.setTexture(reference, index: 0)
        encoder.setTexture(candidate, index: 1)
        encoder.setBuffer(sadBuffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<AlignmentParams>.size, index: 1)

        // One thread per search offset
        let (threadgroups, threadsPerGroup) = metalContext.threadgroupSize(
            for: metalContext.sadPipeline, width: searchDiam, height: searchDiam
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Find the offset with minimum SAD on CPU
        let sadPointer = sadBuffer.contents().bindMemory(to: Float.self, capacity: searchDiam * searchDiam)
        var bestSAD: Float = .infinity
        var bestDx = baseDx
        var bestDy = baseDy
        var bestGridX = searchRadius
        var bestGridY = searchRadius

        for y in 0..<searchDiam {
            for x in 0..<searchDiam {
                let sad = sadPointer[y * searchDiam + x]
                if sad < bestSAD {
                    bestSAD = sad
                    bestDx = x - searchRadius + baseDx
                    bestDy = y - searchRadius + baseDy
                    bestGridX = x
                    bestGridY = y
                }
            }
        }

        return SADResult(dx: bestDx, dy: bestDy, gridX: bestGridX, gridY: bestGridY, sadBuffer: sadBuffer)
    }

    // MARK: - Sub-Pixel Refinement

    /// Parabolic interpolation of SAD values around the minimum for sub-pixel precision.
    private func subPixelRefine(sadPointer: UnsafePointer<Float>, searchDiam: Int) -> (Float, Float) {
        // Find minimum again to get the grid position
        var bestSAD: Float = .infinity
        var bestX = 0
        var bestY = 0
        for y in 0..<searchDiam {
            for x in 0..<searchDiam {
                let sad = sadPointer[y * searchDiam + x]
                if sad < bestSAD {
                    bestSAD = sad
                    bestX = x
                    bestY = y
                }
            }
        }

        func sad(x: Int, y: Int) -> Float {
            guard x >= 0, x < searchDiam, y >= 0, y < searchDiam else { return Float.infinity }
            return sadPointer[y * searchDiam + x]
        }

        // Parabolic fit in X: vertex = -0.5 * (right - left) / (right - 2*center + left)
        let cx = sad(x: bestX, y: bestY)
        let lx = sad(x: bestX - 1, y: bestY)
        let rx = sad(x: bestX + 1, y: bestY)
        let denomX = lx - 2 * cx + rx
        let subX: Float = (abs(denomX) > 1e-6) ? -0.5 * (rx - lx) / denomX : 0.0

        // Parabolic fit in Y
        let ly = sad(x: bestX, y: bestY - 1)
        let ry = sad(x: bestX, y: bestY + 1)
        let denomY = ly - 2 * cx + ry
        let subY: Float = (abs(denomY) > 1e-6) ? -0.5 * (ry - ly) / denomY : 0.0

        // Clamp to [-0.5, 0.5] to stay within the cell
        return (max(-0.5, min(subX, 0.5)), max(-0.5, min(subY, 0.5)))
    }

    // MARK: - Warp

    private func warpTexture(_ input: MTLTexture, dx: Float, dy: Float) -> MTLTexture? {
        guard let output = texturePool.acquire(width: input.width, height: input.height,
                                                pixelFormat: input.pixelFormat) else { return nil }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        var params = WarpParams(dx: dx, dy: dy)

        encoder.setComputePipelineState(metalContext.warpPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<WarpParams>.size, index: 0)

        let (threadgroups, threadsPerGroup) = metalContext.threadgroupSize(
            for: metalContext.warpPipeline, width: output.width, height: output.height
        )
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return output
    }
}
