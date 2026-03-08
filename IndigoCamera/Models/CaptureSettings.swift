import Foundation
import AVFoundation

/// All user-adjustable camera and processing settings.
final class CaptureSettings: ObservableObject {
    // MARK: - Camera Controls

    /// Whether each control is in auto or manual mode
    @Published var isAutoExposure = true
    @Published var isAutoFocus = true
    @Published var isAutoWhiteBalance = true

    /// ISO sensitivity (25-3072 on iPhone 13)
    @Published var iso: Float = 100

    /// Shutter speed in seconds (e.g., 1/60 = 0.0167)
    @Published var shutterSpeed: Double = 1.0 / 60.0

    /// Focus position: 0.0 (infinity) to 1.0 (nearest)
    @Published var focusPosition: Float = 0.5

    /// White balance temperature in Kelvin (2000-10000)
    @Published var wbTemperature: Float = 5500

    /// White balance tint (-150 to +150)
    @Published var wbTint: Float = 0

    // MARK: - Burst / Multi-Frame Settings

    /// Number of frames to capture and merge (1-16)
    @Published var frameCount: Int = 8

    // MARK: - Capture Mode

    /// Current capture mode (Quick / Stack / Super-Res)
    @Published var captureMode: CaptureMode = .quick

    /// Super-resolution upscale factor (derived from capture mode)
    var superResScale: Float {
        captureMode.upscaleFactor
    }

    // MARK: - Tone Mapping

    /// Exposure compensation in EV for tone mapping
    var toneMapExposure: Float = 0.0

    /// Mid-tone contrast strength (0.0 = flat, 0.5 = strong)
    var toneMapContrast: Float = 0.15

    /// Shadow lift amount (0.0 = pure black, 0.05 = lifted)
    var toneMapShadowLift: Float = 0.02

    /// Merge sigma for robustness (adapts to ISO)
    var mergeSigma: Float {
        // Higher ISO = more noise = need higher sigma to tolerate differences
        let normalizedISO = iso / 100.0
        return 0.05 * max(1.0, sqrt(normalizedISO))
    }

    // MARK: - Computed Helpers

    /// Shutter speed as CMTime
    var shutterSpeedCMTime: CMTime {
        CMTime(seconds: shutterSpeed, preferredTimescale: 1_000_000)
    }

    /// Format shutter speed for display (e.g., "1/60")
    var shutterSpeedDisplay: String {
        if shutterSpeed >= 1.0 {
            return String(format: "%.1fs", shutterSpeed)
        } else {
            let denominator = Int(round(1.0 / shutterSpeed))
            return "1/\(denominator)"
        }
    }
}
