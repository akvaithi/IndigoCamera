import Metal
import CoreImage
import UIKit

/// Applies natural SLR-like tone mapping and color adjustments.
/// Combines a Metal-based filmic tone curve with Core Image post-processing.
final class ToneMapper {
    private let metalContext: MetalContext
    private let texturePool: TexturePool
    private let ciContext: CIContext

    init(metalContext: MetalContext, texturePool: TexturePool) {
        self.metalContext = metalContext
        self.texturePool = texturePool
        // Use Metal-backed CIContext for efficient GPU processing
        self.ciContext = CIContext(mtlDevice: metalContext.device, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
        ])
    }

    /// Apply filmic tone mapping via Metal shader.
    /// Input: linear-light merged texture (rgba16Float).
    /// Output: sRGB gamma-encoded texture ready for display/JPEG.
    func applyToneMap(to input: MTLTexture, settings: CaptureSettings) -> MTLTexture? {
        guard let output = texturePool.acquire(width: input.width, height: input.height,
                                                pixelFormat: .rgba16Float) else { return nil }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        // Compute exposure compensation
        let exposure = settings.toneMapExposure

        var params = ToneMapParams(
            exposure: exposure,
            contrast: settings.toneMapContrast,
            shadowLift: settings.toneMapShadowLift,
            whitePoint: 4.0
        )

        encoder.setComputePipelineState(metalContext.tonemapPipeline)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ToneMapParams>.size, index: 0)

        let (tg, tpg) = metalContext.threadgroupSize(
            for: metalContext.tonemapPipeline,
            width: output.width, height: output.height
        )
        encoder.dispatchThreadgroups(tg, threadsPerThreadgroup: tpg)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return output
    }

    /// Apply subtle Core Image adjustments (vibrance, sharpening).
    /// Input: sRGB-encoded CIImage.
    /// Output: adjusted CIImage.
    func applyCoreImageAdjustments(to image: CIImage) -> CIImage {
        var output = image

        // Subtle vibrance (boosts undersaturated colors without oversaturating)
        if let vibrance = CIFilter(name: "CIVibrance") {
            vibrance.setValue(output, forKey: kCIInputImageKey)
            vibrance.setValue(0.1, forKey: "inputAmount")
            if let result = vibrance.outputImage {
                output = result
            }
        }

        // Mild luminance sharpening
        if let sharpen = CIFilter(name: "CISharpenLuminance") {
            sharpen.setValue(output, forKey: kCIInputImageKey)
            sharpen.setValue(0.3, forKey: kCIInputSharpnessKey)
            if let result = sharpen.outputImage {
                output = result
            }
        }

        return output
    }

    /// Convert a Metal texture to a CIImage for Core Image processing.
    func textureToImage(_ texture: MTLTexture) -> CIImage? {
        return CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ])
    }

    /// Render a CIImage to a UIImage.
    func renderToUIImage(_ image: CIImage) -> UIImage? {
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    /// Full tone mapping pipeline: Metal shader + Core Image adjustments -> UIImage.
    func process(mergedTexture: MTLTexture, settings: CaptureSettings) -> UIImage? {
        // 1. Apply Metal-based filmic tone map
        guard let toneMapped = applyToneMap(to: mergedTexture, settings: settings) else {
            Log.processing.error("Tone mapping failed")
            return nil
        }

        // 2. Convert to CIImage
        guard var ciImage = textureToImage(toneMapped) else {
            Log.processing.error("Texture to CIImage conversion failed")
            return nil
        }

        // 3. Apply Core Image adjustments
        ciImage = applyCoreImageAdjustments(to: ciImage)

        // 4. Render to UIImage
        guard let uiImage = renderToUIImage(ciImage) else {
            Log.processing.error("CIImage to UIImage rendering failed")
            return nil
        }

        texturePool.release(toneMapped)
        return uiImage
    }
}
