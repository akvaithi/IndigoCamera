import Foundation

/// Capture modes available in the app.
enum CaptureMode: String, CaseIterable, Identifiable {
    case quick     // Single-frame DNG via AVCapturePhotoOutput
    case stack     // HDR: exposure-bracketed RAW frames, fused for extended dynamic range
    case superRes  // Multi-frame sub-pixel aligned, accumulated on 1.5x upscaled grid

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick:    return "Quick"
        case .stack:    return "Stack"
        case .superRes: return "Super-Res"
        }
    }

    var defaultFrameCount: Int {
        switch self {
        case .quick:    return 1
        case .stack:    return 8
        case .superRes: return 8
        }
    }

    /// The upscale factor for the output grid.
    /// 1.5x upscale: 4032x3024 -> 6048x4536 (~27MP from 12MP sensor).
    var upscaleFactor: Float {
        switch self {
        case .quick, .stack: return 1.0
        case .superRes:      return 1.5
        }
    }
}
