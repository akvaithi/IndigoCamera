# IndigoCamera

A computational photography camera app for iPhone, built with Swift and Metal. IndigoCamera captures RAW DNG photos and processes them using multi-frame techniques to produce images with higher dynamic range and higher resolution than a single shot.

Designed for iPhone 13 (A15 Bionic, 12MP wide sensor). Output is 16-bit TIFF in sRGB, ready for editing in Lightroom or any photo editor that supports TIFF.

## Capture Modes

### Quick
Single-frame RAW DNG capture via `AVCapturePhotoOutput`. Saves the unprocessed DNG directly to the Photos library. Use this when you want the raw sensor data for manual editing.

### Stack (HDR)
Captures a burst of exposure-bracketed RAW frames spanning a +/-2 EV range (e.g., 5 frames at -2, -1, 0, +1, +2 EV). Each frame is demosaiced with EV compensation to normalize brightness, then aligned and merged using robust Cauchy-weighted averaging. The result is a 16-bit TIFF with extended dynamic range -- short exposures contribute clean highlights, long exposures contribute clean shadows.

### Super-Res
Captures a burst of RAW frames at the same exposure and merges them onto a 1.5x upscaled grid (4032x3024 -> 6048x4536, ~27MP from a 12MP sensor). Natural hand tremor between frames provides sub-pixel diversity. Each frame is aligned with sub-pixel precision at native resolution, then warped and upsampled to the high-res grid. Cauchy-weighted merging rejects outliers and accumulates genuine detail beyond what a single frame can resolve.

## Architecture

```
IndigoCamera/
├── App/                        # App entry point and global state
├── Camera/                     # AVCaptureSession, device controls, capture orchestration
│   ├── CameraManager           # Session setup, video/photo output, live metadata
│   ├── CameraConfigurator      # Manual ISO, shutter speed, focus, white balance
│   ├── CaptureCoordinator      # Multi-mode capture orchestrator (Quick/Stack/Super-Res)
│   └── FrameRingBuffer         # Lock-free circular buffer for zero-shutter-lag capture
├── Metal/                      # GPU compute infrastructure
│   ├── MetalContext            # Device, queue, 12 pre-compiled pipeline states
│   ├── TexturePool             # Object pool for MTLTexture reuse
│   ├── ShaderTypes.h           # C structs shared between Metal and Swift
│   └── Shaders/
│       ├── Alignment.metal     # Pyramid SAD search + sub-pixel warp
│       ├── Merge.metal         # Cauchy-weighted merge + HDR exposure fusion
│       ├── SuperResolution.metal # Warp+upsample to high-res grid
│       ├── Conversion.metal    # Grayscale, downsample, clear
│       └── ToneMap.metal       # ACES-inspired filmic tone mapping
├── Models/                     # Data types
│   ├── CaptureMode             # Quick / Stack / Super-Res enum
│   ├── CaptureSettings         # All user-adjustable parameters
│   └── CaptureResult           # Output data model
├── Processing/                 # Image processing pipeline
│   ├── ProcessingPipeline      # Orchestrates the full processing chain
│   ├── RAWDemosacer            # CIRAWFilter DNG -> linear rgba16Float textures
│   ├── FrameAligner            # 4-level pyramid alignment with sub-pixel refinement
│   ├── FrameMerger             # Robust Cauchy-weighted frame accumulation
│   ├── SuperResolutionMerger   # Upscaled-grid accumulation for super-resolution
│   ├── ToneMapper              # Filmic tone mapping + CIFilter post-processing
│   ├── LinearDNGWriter         # 16-bit TIFF writer with EXIF metadata
│   └── OutputEncoder           # JPEG/DNG encoding + Photos library saving
├── UI/                         # SwiftUI interface
│   ├── CameraView              # Main camera screen
│   ├── MetalPreviewView        # Live camera preview (AVCaptureVideoPreviewLayer)
│   ├── ManualControlsOverlay   # ISO, shutter, focus, WB sliders
│   ├── ModeSelector            # Quick/Stack/Super-Res pill selector
│   ├── ShutterButton           # Animated shutter with haptics
│   ├── ProcessingIndicatorView # Progress bar during multi-frame processing
│   ├── ReviewView              # Post-capture image review sheet
│   ├── FrameCountPicker        # Burst frame count dropdown
│   └── OutputFormatPicker      # JPG/DNG toggle
└── Utilities/
    ├── Logger                  # os.Logger subsystems (camera, processing, metal, memory, export)
    └── CVPixelBuffer+Extensions # Zero-copy CVPixelBuffer -> MTLTexture
```

## Processing Pipeline

The entire image processing chain runs on the GPU via Metal compute shaders. All 12 pipeline states are pre-compiled at launch.

### Alignment
A coarse-to-fine 4-level image pyramid (4032 -> 2016 -> 1008 -> 504). At the coarsest level, an exhaustive 65x65 SAD search finds the best global translation. At each finer level, the search narrows to a 5x5 window around the upscaled estimate. At the finest level, parabolic interpolation of the SAD surface provides sub-pixel precision. The final warp uses bilinear interpolation.

### Merging
Cauchy (Lorentzian) per-pixel weighting: `w = 1 / (1 + (diff/sigma)^2)`. This is inherently robust to outliers -- moving objects that don't match the reference frame get near-zero weight, preventing ghosting without explicit motion detection. The noise-adaptive sigma scales with `sqrt(ISO/100)`.

### HDR Bracket Normalization
Each bracketed frame is captured at a different shutter speed but the same ISO. During demosaicing, `CIRAWFilter.exposure` is set to the negative of the capture EV offset, normalizing all frames to the same apparent brightness. This allows the standard Cauchy merge to combine them.

### Super-Resolution Upsampling
Each candidate frame is aligned at native resolution, then warped and upsampled to the 1.5x output grid via the `superres_warp_kernel`. The warp uses bilinear interpolation with the sub-pixel alignment offset, placing each frame's pixel data at the correct fractional position on the high-res grid. Cauchy weights compare warped candidates against the upsampled reference at the output resolution.

### Memory Management
The pipeline processes one DNG frame at a time (demosaic -> align -> merge -> release), keeping peak GPU memory under control:
- **HDR Stack**: ~340MB peak (1 input texture + native-res accumulators)
- **Super-Res**: ~590MB peak (1 input texture + reference + 1.5x accumulators)

A `TexturePool` recycles `MTLTexture` objects to avoid allocation churn. `os_proc_available_memory()` is queried at runtime to compute safe frame counts. Memory warnings trigger pool purging and ring buffer clearing.

## RAW Processing

DNG demosaicing uses `CIRAWFilter` (iOS 15+) with all processing disabled:
- No sharpening (`sharpnessAmount = 0`)
- No noise reduction (`luminanceNoiseReductionAmount = 0`, `colorNoiseReductionAmount = 0`)
- No moire reduction (`moireReductionAmount = 0`)

This produces clean linear-light data in linear sRGB, ideal for stacking. Tone mapping and gamma encoding are applied only at the final output stage.

## Output

- **Quick mode**: Raw DNG file saved to Photos
- **Stack and Super-Res modes**: 16-bit LZW-compressed TIFF with sRGB gamma encoding and full EXIF metadata (ISO, exposure time, focal length, f-number, capture date)

The sRGB transfer function is applied precisely (linear segment below 0.0031308, power curve above). Output TIFFs are saved via a temporary file to handle large image sizes reliably.

## UI

The camera interface is portrait-only with a dark theme:
- **Top bar**: RAW badge, frame count picker (hidden in Quick mode), live ISO and shutter speed readout
- **Preview**: Full-sensor 4:3 aspect ratio via `AVCaptureVideoPreviewLayer`
- **Bottom bar**: Last-captured thumbnail, shutter button with haptic feedback, mode selector
- **Manual controls**: Slide-out overlay with logarithmic sliders for ISO (25-3072), shutter speed, focus (0-1), white balance temperature (2000-10000K), and tint (-150 to +150). Each parameter has an auto/manual toggle
- **Processing indicator**: Animated progress bar with percentage during multi-frame capture and processing
- **Review sheet**: Full-screen image review with share button

## Requirements

- iOS 16.0+
- iPhone with RAW capture support (iPhone 12 and later)
- Camera and Photo Library (write-only) permissions

## Building

Open `IndigoCamera.xcodeproj` in Xcode and build for a physical iOS device. The app requires a real camera and cannot run in the simulator.

## License

This project is provided as-is for educational and personal use.
