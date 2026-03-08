import UIKit
import Metal

/// Result of the capture and processing pipeline.
struct CaptureResult {
    /// The final processed image as a UIImage (for display and JPEG export)
    let image: UIImage

    /// The final processed Metal texture (before conversion to UIImage)
    let texture: MTLTexture?

    /// Raw DNG data (if DNG capture was requested)
    let dngData: Data?

    /// Capture metadata
    let metadata: CaptureMetadata
}

/// Metadata extracted from the captured frames.
struct CaptureMetadata {
    let captureDate: Date
    let iso: Float
    let exposureDuration: Double
    let focalLength: Float
    let lensAperture: Float
    let frameCount: Int
    let whiteBalanceTemperature: Float
    let whiteBalanceTint: Float
}
