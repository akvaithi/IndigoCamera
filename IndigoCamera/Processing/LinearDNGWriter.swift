import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Photos

/// Writes merged rgba16Float Metal textures as 16-bit linear TIFF files.
/// Lightroom opens 16-bit TIFFs with full editing capability.
final class LinearDNGWriter {

    struct ImageMetadata {
        let iso: Float
        let exposureDuration: Double
        let focalLength: Float
        let aperture: Float
        let frameCount: Int
        let captureDate: Date
        let whiteBalanceTemperature: Float
        let whiteBalanceTint: Float
        let originalWidth: Int
        let originalHeight: Int
    }

    enum WriterError: Error, CustomStringConvertible {
        case readbackFailed
        case cgImageCreationFailed
        case destinationCreationFailed
        case finalizationFailed

        var description: String {
            switch self {
            case .readbackFailed: return "Failed to read texture data from GPU"
            case .cgImageCreationFailed: return "Failed to create CGImage from pixel data"
            case .destinationCreationFailed: return "Failed to create TIFF destination"
            case .finalizationFailed: return "Failed to finalize TIFF file"
            }
        }
    }

    private let metalContext: MetalContext

    init(metalContext: MetalContext) {
        self.metalContext = metalContext
    }

    // MARK: - Public API

    /// Read an rgba16Float MTLTexture, convert to 16-bit TIFF Data.
    func writeTIFF(from texture: MTLTexture, metadata: ImageMetadata) throws -> Data {
        let width = texture.width
        let height = texture.height

        // Step 1: Read back texture to CPU via blit encoder (handles .private storage)
        let float16Data = try readbackTexture(texture)

        // Step 2: Convert Float16 (linear) to UInt16 (sRGB gamma), drop alpha
        let pixelCount = width * height
        var uint16Data = [UInt16](repeating: 0, count: pixelCount * 3)

        for i in 0..<pixelCount {
            uint16Data[i * 3 + 0] = float16ToSRGBUInt16(float16Data[i * 4 + 0])
            uint16Data[i * 3 + 1] = float16ToSRGBUInt16(float16Data[i * 4 + 1])
            uint16Data[i * 3 + 2] = float16ToSRGBUInt16(float16Data[i * 4 + 2])
        }

        // Step 3: Create CGImage
        let rgbBytesPerRow = width * 3 * MemoryLayout<UInt16>.size
        let cgImage = try createCGImage(from: &uint16Data, width: width, height: height,
                                         bytesPerRow: rgbBytesPerRow)

        // Step 4: Write TIFF with metadata
        return try writeTIFFData(cgImage: cgImage, metadata: metadata)
    }

    /// Save TIFF data to the Photos library.
    /// Uses a temporary file to avoid PHPhotos memory limits on large image data
    /// (super-res TIFFs at 6048x4536 can exceed the in-memory data limit).
    func saveToPhotosLibrary(_ tiffData: Data, mode: CaptureMode) async throws {
        let filename = "IndigoCamera_\(Self.filenameTimestamp())_\(mode.rawValue).tiff"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        try tiffData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = UTType.tiff.identifier
            options.originalFilename = filename
            request.addResource(with: .photo, fileURL: tempURL, options: options)
        }
    }

    // MARK: - GPU Readback

    /// Reads an rgba16Float texture back to CPU memory.
    /// Uses a blit encoder to copy from .private storage to a .shared buffer.
    private func readbackTexture(_ texture: MTLTexture) throws -> [UInt16] {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4 * 2  // rgba16Float = 4 channels * 2 bytes each
        let bufferSize = bytesPerRow * height

        guard let sharedBuffer = metalContext.device.makeBuffer(
            length: bufferSize, options: .storageModeShared
        ) else {
            throw WriterError.readbackFailed
        }

        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw WriterError.readbackFailed
        }

        blitEncoder.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: sharedBuffer, destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: bufferSize
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Copy from MTLBuffer to Swift array
        let pixelCount = width * height * 4
        let pointer = sharedBuffer.contents().bindMemory(to: UInt16.self, capacity: pixelCount)
        return Array(UnsafeBufferPointer(start: pointer, count: pixelCount))
    }

    // MARK: - Float16 Conversion

    /// Convert a Float16 bit pattern (linear light) to an sRGB gamma-encoded UInt16 (0-65535).
    /// Applies the standard sRGB transfer function for correct display and Lightroom editing.
    private func float16ToSRGBUInt16(_ f16Bits: UInt16) -> UInt16 {
        let linear = Float(Float16(bitPattern: f16Bits))
        let clamped = max(0.0, min(linear, 1.0))
        let srgb: Float
        if clamped <= 0.0031308 {
            srgb = clamped * 12.92
        } else {
            srgb = 1.055 * pow(clamped, 1.0 / 2.4) - 0.055
        }
        return UInt16(srgb * 65535.0)
    }

    // MARK: - CGImage Creation

    private func createCGImage(from data: inout [UInt16], width: Int, height: Int,
                                bytesPerRow: Int) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw WriterError.cgImageCreationFailed
        }

        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            .byteOrder16Little
        ]

        let dataSize = data.count * MemoryLayout<UInt16>.size
        guard let provider = CGDataProvider(data: Data(
            bytes: &data, count: dataSize
        ) as CFData) else {
            throw WriterError.cgImageCreationFailed
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 48,        // 3 channels * 16 bits
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw WriterError.cgImageCreationFailed
        }

        return cgImage
    }

    // MARK: - TIFF Writing

    private func writeTIFFData(cgImage: CGImage, metadata: ImageMetadata) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.tiff.identifier as CFString, 1, nil
        ) else {
            throw WriterError.destinationCreationFailed
        }

        let dateFormatter = ISO8601DateFormatter()

        let exif: [String: Any] = [
            kCGImagePropertyExifISOSpeedRatings as String: [Int(metadata.iso)],
            kCGImagePropertyExifExposureTime as String: metadata.exposureDuration,
            kCGImagePropertyExifFocalLength as String: metadata.focalLength,
            kCGImagePropertyExifFNumber as String: metadata.aperture,
            kCGImagePropertyExifDateTimeOriginal as String: dateFormatter.string(from: metadata.captureDate),
            kCGImagePropertyExifUserComment as String: "IndigoCamera \(metadata.frameCount)-frame stack"
        ]

        let tiff: [String: Any] = [
            kCGImagePropertyTIFFMake as String: "Apple",
            kCGImagePropertyTIFFModel as String: "iPhone 13",
            kCGImagePropertyTIFFSoftware as String: "IndigoCamera",
            kCGImagePropertyTIFFCompression as String: 5,  // LZW compression
        ]

        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: exif,
            kCGImagePropertyTIFFDictionary as String: tiff,
            kCGImagePropertyColorModel as String: kCGImagePropertyColorModelRGB,
            kCGImagePropertyProfileName as String: "sRGB"
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw WriterError.finalizationFailed
        }

        return data as Data
    }

    // MARK: - Helpers

    private static func filenameTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}
