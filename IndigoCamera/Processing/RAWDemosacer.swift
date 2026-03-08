import CoreImage
import Metal

/// Demosaics RAW DNG data into linear-light Metal textures using CIRAWFilter.
/// Outputs rgba16Float textures in linear sRGB for accurate frame stacking.
@available(iOS 15.0, *)
final class RAWDemosacer {
    private let ciContext: CIContext
    private let metalContext: MetalContext
    private let texturePool: TexturePool

    init(metalContext: MetalContext, texturePool: TexturePool) {
        self.metalContext = metalContext
        self.texturePool = texturePool
        self.ciContext = CIContext(mtlDevice: metalContext.device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
        ])
    }

    /// Demosaic a DNG data blob into a linear rgba16Float Metal texture.
    /// The output is in linear sRGB color space -- ideal for pixel-level merging.
    ///
    /// - Parameters:
    ///   - dngData: Raw DNG file data
    ///   - evCompensation: EV offset applied during rendering. Use this to normalize
    ///     bracketed exposures to the same apparent brightness for alignment/merge.
    ///     E.g., for a frame captured at -2EV, pass +2.0 to bring it to baseline.
    func demosaic(_ dngData: Data, evCompensation: Float = 0) throws -> MTLTexture {
        guard let filter = CIRAWFilter(imageData: dngData, identifierHint: "com.adobe.raw-image") else {
            Log.processing.error("CIRAWFilter failed to initialize from DNG data")
            throw ProcessingError.textureCreationFailed
        }

        // Minimal processing: demosaic + auto white balance only.
        // No sharpening, NR, or tone mapping -- stacking handles noise,
        // and we want clean linear data for merging.
        filter.sharpnessAmount = 0
        filter.luminanceNoiseReductionAmount = 0
        filter.colorNoiseReductionAmount = 0
        filter.moireReductionAmount = 0
        filter.isGamutMappingEnabled = false

        // Apply EV compensation to normalize bracketed exposures.
        // For HDR: a -2EV frame gets +2.0 compensation to match baseline brightness.
        if evCompensation != 0 {
            filter.exposure = evCompensation
            Log.processing.debug("RAW demosaic: EV compensation \(evCompensation)")
        }

        guard let ciImage = filter.outputImage else {
            Log.processing.error("CIRAWFilter produced no output")
            throw ProcessingError.textureCreationFailed
        }

        let width = Int(ciImage.extent.width)
        let height = Int(ciImage.extent.height)

        guard let texture = texturePool.acquire(
            width: width, height: height,
            pixelFormat: .rgba16Float
        ) else {
            throw ProcessingError.textureCreationFailed
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            throw ProcessingError.textureCreationFailed
        }

        ciContext.render(ciImage, to: texture, commandBuffer: commandBuffer,
                         bounds: ciImage.extent, colorSpace: colorSpace)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        Log.processing.info("RAW demosaic: \(width)x\(height)")
        return texture
    }
}
