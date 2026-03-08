import Metal

/// A pool of reusable MTLTextures to reduce allocation overhead.
/// Textures are matched by (width, height, pixelFormat) for reuse.
final class TexturePool {
    private let device: MTLDevice
    private var available: [TextureKey: [MTLTexture]] = [:]

    private struct TextureKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: MTLPixelFormat
    }

    init(device: MTLDevice) {
        self.device = device
    }

    /// Acquire a texture with the given dimensions and format.
    /// Returns a reused texture if available, or allocates a new one.
    func acquire(width: Int, height: Int,
                 pixelFormat: MTLPixelFormat = .rgba16Float,
                 usage: MTLTextureUsage = [.shaderRead, .shaderWrite],
                 storageMode: MTLStorageMode = .private) -> MTLTexture? {
        let key = TextureKey(width: width, height: height, pixelFormat: pixelFormat)

        if var pool = available[key], let texture = pool.popLast() {
            available[key] = pool
            return texture
        }

        // Allocate a new texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = usage
        descriptor.storageMode = storageMode

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            Log.metal.error("Failed to allocate texture \(width)x\(height)")
            return nil
        }
        return texture
    }

    /// Acquire a texture matching the dimensions of another texture.
    func acquire(matching other: MTLTexture,
                 pixelFormat: MTLPixelFormat? = nil,
                 storageMode: MTLStorageMode = .private) -> MTLTexture? {
        acquire(width: other.width,
                height: other.height,
                pixelFormat: pixelFormat ?? other.pixelFormat,
                storageMode: storageMode)
    }

    /// Return a texture to the pool for reuse.
    func release(_ texture: MTLTexture) {
        let key = TextureKey(width: texture.width,
                             height: texture.height,
                             pixelFormat: texture.pixelFormat)
        available[key, default: []].append(texture)
    }

    /// Release all pooled textures (call on memory warning).
    func purge() {
        let count = available.values.reduce(0) { $0 + $1.count }
        available.removeAll()
        Log.memory.info("TexturePool purged \(count) textures")
    }
}
