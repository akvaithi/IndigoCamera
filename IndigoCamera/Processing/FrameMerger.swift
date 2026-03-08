import Metal

/// Merges aligned burst frames using a robust weighted average.
/// Uses Cauchy (Lorentzian) weighting to avoid ghosting from moving objects.
final class FrameMerger {
    private let metalContext: MetalContext
    private let texturePool: TexturePool

    init(metalContext: MetalContext, texturePool: TexturePool) {
        self.metalContext = metalContext
        self.texturePool = texturePool
    }

    /// Create and return accumulator textures (color + weight), both cleared to zero.
    func createAccumulators(width: Int, height: Int) -> (color: MTLTexture, weight: MTLTexture)? {
        guard let accumColor = texturePool.acquire(width: width, height: height,
                                                    pixelFormat: .rgba16Float),
              let accumWeight = texturePool.acquire(width: width, height: height,
                                                     pixelFormat: .r16Float) else {
            return nil
        }

        // Clear both to zero
        clearTexture(accumColor)
        clearTexture(accumWeight)

        return (accumColor, accumWeight)
    }

    /// Add a frame into the accumulators with the given merge parameters.
    func accumulate(frame: MTLTexture,
                    reference: MTLTexture,
                    accumColor: MTLTexture,
                    accumWeight: MTLTexture,
                    sigma: Float,
                    baseWeight: Float) {

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else { return }

        // 1. Compute per-pixel merge weights
        guard let weights = texturePool.acquire(width: frame.width, height: frame.height,
                                                 pixelFormat: .r16Float) else { return }

        // Weight computation
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var params = MergeParams(sigma: sigma, frameWeight: baseWeight)

            encoder.setComputePipelineState(metalContext.mergeWeightPipeline)
            encoder.setTexture(reference, index: 0)
            encoder.setTexture(frame, index: 1)
            encoder.setTexture(weights, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<MergeParams>.size, index: 0)

            let (tg, tpg) = metalContext.threadgroupSize(
                for: metalContext.mergeWeightPipeline,
                width: frame.width, height: frame.height
            )
            encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        // 2. Accumulate weighted frame
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(metalContext.accumulatePipeline)
            encoder.setTexture(frame, index: 0)
            encoder.setTexture(weights, index: 1)
            encoder.setTexture(accumColor, index: 2)
            encoder.setTexture(accumWeight, index: 3)

            let (tg, tpg) = metalContext.threadgroupSize(
                for: metalContext.accumulatePipeline,
                width: frame.width, height: frame.height
            )
            encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        texturePool.release(weights)
    }

    /// Normalize the accumulators to produce the final merged image.
    func normalize(accumColor: MTLTexture, accumWeight: MTLTexture) -> MTLTexture? {
        guard let output = texturePool.acquire(width: accumColor.width,
                                                height: accumColor.height,
                                                pixelFormat: .rgba16Float) else { return nil }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(metalContext.normalizePipeline)
        encoder.setTexture(accumColor, index: 0)
        encoder.setTexture(accumWeight, index: 1)
        encoder.setTexture(output, index: 2)

        let (tg, tpg) = metalContext.threadgroupSize(
            for: metalContext.normalizePipeline,
            width: output.width, height: output.height
        )
        encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return output
    }

    // MARK: - HDR Exposure Fusion

    /// Add a frame into the accumulators using HDR exposure fusion weighting.
    /// Unlike the standard merge, this weights pixels by well-exposedness (Mertens algorithm)
    /// rather than similarity to a reference. Each exposure contributes its best pixels.
    func accumulateHDR(frame: MTLTexture,
                       accumColor: MTLTexture,
                       accumWeight: MTLTexture,
                       sigma: Float,
                       baseWeight: Float) {

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else { return }

        // 1. Compute per-pixel HDR fusion weights (well-exposedness * saturation)
        guard let weights = texturePool.acquire(width: frame.width, height: frame.height,
                                                 pixelFormat: .r16Float) else { return }

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            var params = MergeParams(sigma: sigma, frameWeight: baseWeight)

            encoder.setComputePipelineState(metalContext.hdrFusionWeightPipeline)
            encoder.setTexture(frame, index: 0)
            encoder.setTexture(weights, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<MergeParams>.size, index: 0)

            let (tg, tpg) = metalContext.threadgroupSize(
                for: metalContext.hdrFusionWeightPipeline,
                width: frame.width, height: frame.height
            )
            encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        // 2. Accumulate weighted frame (reuses standard accumulate kernel)
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(metalContext.accumulatePipeline)
            encoder.setTexture(frame, index: 0)
            encoder.setTexture(weights, index: 1)
            encoder.setTexture(accumColor, index: 2)
            encoder.setTexture(accumWeight, index: 3)

            let (tg, tpg) = metalContext.threadgroupSize(
                for: metalContext.accumulatePipeline,
                width: frame.width, height: frame.height
            )
            encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
            encoder.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        texturePool.release(weights)
    }

    // MARK: - Helpers

    private func clearTexture(_ texture: MTLTexture) {
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(metalContext.clearPipeline)
        encoder.setTexture(texture, index: 0)

        let (tg, tpg) = metalContext.threadgroupSize(
            for: metalContext.clearPipeline,
            width: texture.width, height: texture.height
        )
        encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
