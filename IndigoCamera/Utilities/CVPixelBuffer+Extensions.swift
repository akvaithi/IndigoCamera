import CoreVideo
import Metal

/// Helpers for working with CVPixelBuffers and Metal textures.
extension CVPixelBuffer {
    /// Width of the pixel buffer in pixels.
    var width: Int { CVPixelBufferGetWidth(self) }

    /// Height of the pixel buffer in pixels.
    var height: Int { CVPixelBufferGetHeight(self) }

    /// Bytes per row (stride) of the pixel buffer.
    var bytesPerRow: Int { CVPixelBufferGetBytesPerRow(self) }

    /// Create a Metal texture from a BGRA CVPixelBuffer using a texture cache.
    /// This is a zero-copy operation - the texture shares the pixel buffer's memory.
    func toMTLTexture(textureCache: CVMetalTextureCache,
                      pixelFormat: MTLPixelFormat = .bgra8Unorm) -> MTLTexture? {
        var cvMetalTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            self,
            nil,
            pixelFormat,
            width,
            height,
            0,  // plane index (0 for BGRA, single plane)
            &cvMetalTexture
        )

        guard status == kCVReturnSuccess, let metalTexture = cvMetalTexture else {
            Log.metal.error("Failed to create Metal texture from CVPixelBuffer: \(status)")
            return nil
        }

        return CVMetalTextureGetTexture(metalTexture)
    }
}
