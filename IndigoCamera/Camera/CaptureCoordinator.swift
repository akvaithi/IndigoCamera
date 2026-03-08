import AVFoundation
import UIKit
import Photos
import ImageIO
import CoreImage
import Metal

/// Multi-mode capture coordinator.
/// Supports Quick (single DNG), Stack (burst RAW merged TIFF), and Super-Res modes.
final class CaptureCoordinator: NSObject, ObservableObject {
    @Published var isCapturing = false
    @Published var lastCapturedImage: UIImage?
    @Published var lastSaveError: String?
    @Published var processingProgress: Float = 0

    private let cameraManager: CameraManager
    private let pipeline: ProcessingPipeline
    private let dngWriter: LinearDNGWriter
    private let processingQueue = DispatchQueue(label: "com.indigo.processing", qos: .userInitiated)

    // Burst RAW capture state
    private var burstContinuation: CheckedContinuation<Data, Error>?
    private var isBurstCapturing = false

    init(cameraManager: CameraManager, metalContext: MetalContext) {
        self.cameraManager = cameraManager
        self.pipeline = ProcessingPipeline(metalContext: metalContext)
        self.dngWriter = LinearDNGWriter(metalContext: metalContext)
        super.init()
    }

    // MARK: - Capture Entry Point

    func capturePhoto(mode: CaptureMode, settings: CaptureSettings) {
        guard !isCapturing else {
            Log.camera.warning("Capture already in progress")
            return
        }

        guard cameraManager.captureSession.isRunning else {
            Log.camera.error("Session not running")
            return
        }

        isCapturing = true
        lastSaveError = nil
        processingProgress = 0

        switch mode {
        case .quick:
            captureSingleFrameDNG()
        case .stack:
            captureHDRStack(settings: settings)
        case .superRes:
            captureSuperRes(settings: settings)
        }
    }

    // MARK: - Quick Mode (Single-Frame DNG)

    private func captureSingleFrameDNG() {
        let photoOutput = cameraManager.photoOutput
        let rawFormats = photoOutput.availableRawPhotoPixelFormatTypes
        Log.camera.info("Available RAW formats: \(rawFormats.map { String(format: "%08X", $0) })")

        guard let rawFormat = rawFormats.first else {
            Log.camera.error("No RAW formats available on this device")
            DispatchQueue.main.async {
                self.lastSaveError = "RAW capture not supported"
                self.isCapturing = false
            }
            return
        }

        let photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        Log.camera.info("Capturing DNG (rawFormat=\(String(format: "%08X", rawFormat)))")
        cameraManager.photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    // MARK: - Stack Mode (HDR Exposure Bracketed RAW)

    private func captureHDRStack(settings: CaptureSettings) {
        let frameCount = settings.frameCount
        let photoOutput = cameraManager.photoOutput
        guard let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            DispatchQueue.main.async {
                self.lastSaveError = "RAW capture not supported"
                self.isCapturing = false
            }
            return
        }

        Log.camera.info("Starting HDR Stack: \(frameCount) bracketed RAW frames")

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Phase 1: Capture bracketed RAW photos (0% - 30%)
                let evSteps = Self.generateEVBracket(frameCount: frameCount)
                var dngFrames = try await self.captureBracketedRAW(
                    evSteps: evSteps, photoOutput: photoOutput, rawFormat: rawFormat
                )
                Log.camera.info("HDR capture complete: \(dngFrames.count) bracketed DNGs")

                // Restore auto exposure after bracketed capture
                self.cameraManager.configurator?.setAutoExposure()

                // Phase 2+3: Stream demosaic + align + merge one frame at a time (30% - 90%)
                // Each frame is demosaiced, EV-compensated, aligned, merged, then released.
                // Peak memory: ~340MB (1 texture + accumulators + aligned texture).
                let evCompensations = evSteps.map { -$0 }
                let mergedTexture = try self.pipeline.streamHDR(
                    dngFrames: &dngFrames, evOffsets: evCompensations, settings: settings
                ) { p in
                    Task { @MainActor in self.processingProgress = 0.3 + p * 0.6 }
                }

                // Phase 4: Write TIFF and save (90% - 100%)
                let metadata = self.collectMetadata(frameCount: frameCount, settings: settings)
                let thumbnail = self.generateThumbnail(from: mergedTexture)

                let tiffData = try self.dngWriter.writeTIFF(from: mergedTexture, metadata: metadata)
                Log.export.info("HDR TIFF: \(tiffData.count) bytes (\(mergedTexture.width)x\(mergedTexture.height))")

                self.pipeline.releaseTexture(mergedTexture)

                try await self.dngWriter.saveToPhotosLibrary(tiffData, mode: .stack)
                Log.export.info("HDR TIFF saved to Photos")

                await MainActor.run {
                    self.lastCapturedImage = thumbnail
                    self.isCapturing = false
                    self.processingProgress = 1.0
                }
            } catch {
                self.cameraManager.configurator?.setAutoExposure()
                Log.export.error("HDR Stack failed: \(error)")
                await MainActor.run {
                    self.lastSaveError = "HDR Stack failed: \(error)"
                    self.isCapturing = false
                }
            }
        }
    }

    // MARK: - Super-Res Mode (Burst RAW for Resolution Upscaling)

    private func captureSuperRes(settings: CaptureSettings) {
        let frameCount = settings.frameCount
        let photoOutput = cameraManager.photoOutput
        guard let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            DispatchQueue.main.async {
                self.lastSaveError = "RAW capture not supported"
                self.isCapturing = false
            }
            return
        }

        Log.camera.info("Starting Super-Res: \(frameCount) RAW frames at \(CaptureMode.superRes.upscaleFactor)x")

        Task { [weak self] in
            guard let self = self else { return }
            do {
                // Phase 1: Capture N RAW photos at same exposure (0% - 30%)
                var dngFrames = try await self.captureBurstRAW(
                    count: frameCount, photoOutput: photoOutput, rawFormat: rawFormat
                )
                Log.camera.info("Super-Res capture complete: \(dngFrames.count) DNGs")

                // Phase 2+3: Stream demosaic + align + warp+upsample + merge (30% - 90%)
                // Each frame is demosaiced, aligned at native res, warped to high-res grid,
                // merged into accumulators, then released. Peak memory: ~590MB for 1.5x.
                let scale = CaptureMode.superRes.upscaleFactor
                let mergedTexture = try self.pipeline.streamSuperRes(
                    dngFrames: &dngFrames, scale: scale, settings: settings
                ) { p in
                    Task { @MainActor in self.processingProgress = 0.3 + p * 0.6 }
                }
                Log.processing.info("Super-Res output: \(mergedTexture.width)x\(mergedTexture.height)")

                // Phase 4: Write TIFF and save (90% - 100%)
                let metadata = self.collectMetadata(frameCount: frameCount, settings: settings)
                let thumbnail = self.generateThumbnail(from: mergedTexture)

                let tiffData = try self.dngWriter.writeTIFF(from: mergedTexture, metadata: metadata)
                Log.export.info("Super-Res TIFF: \(tiffData.count) bytes (\(mergedTexture.width)x\(mergedTexture.height))")

                self.pipeline.releaseTexture(mergedTexture)

                try await self.dngWriter.saveToPhotosLibrary(tiffData, mode: .superRes)
                Log.export.info("Super-Res TIFF saved to Photos")

                await MainActor.run {
                    self.lastCapturedImage = thumbnail
                    self.isCapturing = false
                    self.processingProgress = 1.0
                }
            } catch {
                Log.export.error("Super-Res failed: \(error)")
                await MainActor.run {
                    self.lastSaveError = "Super-Res failed: \(error)"
                    self.isCapturing = false
                }
            }
        }
    }

    // MARK: - Burst RAW Capture

    /// Capture N RAW photos sequentially using AVCapturePhotoOutput.
    /// Each capture waits for the delegate callback before starting the next.
    private func captureBurstRAW(count: Int,
                                 photoOutput: AVCapturePhotoOutput,
                                 rawFormat: OSType) async throws -> [Data] {
        isBurstCapturing = true
        defer { isBurstCapturing = false }

        var dngFrames: [Data] = []
        dngFrames.reserveCapacity(count)

        for i in 0..<count {
            let dngData = try await captureOneRAW(photoOutput: photoOutput, rawFormat: rawFormat)
            dngFrames.append(dngData)
            Log.camera.info("Burst frame \(i + 1)/\(count): \(dngData.count) bytes")
            await MainActor.run {
                self.processingProgress = Float(i + 1) / Float(count) * 0.3
            }
        }

        return dngFrames
    }

    /// Capture a single RAW photo and return the DNG data via async/await.
    private func captureOneRAW(photoOutput: AVCapturePhotoOutput,
                               rawFormat: OSType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.burstContinuation = continuation
            let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Bracketed RAW Capture (HDR)

    /// Capture RAW photos at different exposure levels for HDR.
    /// Locks exposure manually for each frame at the specified EV offset from the metered exposure.
    private func captureBracketedRAW(evSteps: [Float],
                                      photoOutput: AVCapturePhotoOutput,
                                      rawFormat: OSType) async throws -> [Data] {
        isBurstCapturing = true
        defer { isBurstCapturing = false }

        guard let configurator = cameraManager.configurator else {
            throw ProcessingError.textureCreationFailed
        }

        // Record the current auto-metered exposure as our base
        let baseISO = cameraManager.currentISO
        let baseDuration = cameraManager.currentExposureDuration

        Log.camera.info("HDR base exposure: ISO \(baseISO), \(baseDuration)s")

        var dngFrames: [Data] = []
        dngFrames.reserveCapacity(evSteps.count)

        for (i, ev) in evSteps.enumerated() {
            // Compute exposure duration for this EV offset
            // EV+1 = 2x duration (brighter), EV-1 = 0.5x duration (darker)
            let evMultiplier = pow(2.0, Double(ev))
            let targetDuration = baseDuration * evMultiplier
            let clampedDuration = CMTime(
                seconds: max(configurator.minExposureDuration.seconds,
                             min(targetDuration, configurator.maxExposureDuration.seconds)),
                preferredTimescale: 1_000_000
            )

            // Lock exposure for this bracket
            configurator.setManualExposure(duration: clampedDuration, iso: baseISO)

            // Wait for the exposure to settle
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms

            let dngData = try await captureOneRAW(photoOutput: photoOutput, rawFormat: rawFormat)
            dngFrames.append(dngData)
            Log.camera.info("HDR frame \(i + 1)/\(evSteps.count): EV\(ev >= 0 ? "+" : "")\(ev), \(dngData.count) bytes")
            await MainActor.run {
                self.processingProgress = Float(i + 1) / Float(evSteps.count) * 0.3
            }
        }

        return dngFrames
    }

    /// Generate EV bracket values distributed evenly across a ±2 EV range.
    /// E.g., 5 frames → [-2, -1, 0, +1, +2], 3 frames → [-2, 0, +2]
    private static func generateEVBracket(frameCount: Int) -> [Float] {
        let totalRange: Float = 4.0  // -2 to +2 EV
        if frameCount == 1 { return [0.0] }
        let step = totalRange / Float(frameCount - 1)
        return (0..<frameCount).map { -2.0 + step * Float($0) }
    }

    // MARK: - Save DNG (Quick Mode)

    private func saveDNGData(_ dngData: Data) {
        if let source = CGImageSourceCreateWithData(dngData as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: 300,
                kCGImageSourceCreateThumbnailFromImageAlways: true
            ]
            if let cgThumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                let thumb = UIImage(cgImage: cgThumb)
                DispatchQueue.main.async {
                    self.lastCapturedImage = thumb
                }
            }
        }

        let filename = "IndigoCamera_\(Self.filenameTimestamp())_quick.dng"
        Task {
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.uniformTypeIdentifier = "com.adobe.raw-image"
                    options.originalFilename = filename
                    request.addResource(with: .photo, data: dngData, options: options)
                }
                Log.export.info("DNG saved to Photos (\(dngData.count) bytes)")
            } catch {
                Log.export.error("DNG save failed: \(error.localizedDescription)")
                await MainActor.run {
                    self.lastSaveError = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Thumbnail Generation

    private func generateThumbnail(from texture: MTLTexture) -> UIImage? {
        guard let ciImage = CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!
        ]) else { return nil }

        let flipped = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ciImage.extent.height))
        let scale = 300.0 / max(flipped.extent.width, flipped.extent.height)
        let scaled = flipped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Metadata

    private func collectMetadata(frameCount: Int, settings: CaptureSettings) -> LinearDNGWriter.ImageMetadata {
        return LinearDNGWriter.ImageMetadata(
            iso: cameraManager.currentISO,
            exposureDuration: cameraManager.currentExposureDuration,
            focalLength: 5.1,
            aperture: 1.6,
            frameCount: frameCount,
            captureDate: Date(),
            whiteBalanceTemperature: settings.wbTemperature,
            whiteBalanceTint: settings.wbTint,
            originalWidth: 4032,
            originalHeight: 3024
        )
    }

    // MARK: - Memory Warning

    func handleMemoryWarning() {
        cameraManager.frameRingBuffer.clear()
        pipeline.purge()
        Log.camera.warning("Memory warning handled: cleared ring buffer and texture pool")
    }

    // MARK: - Helpers

    private static func filenameTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CaptureCoordinator: AVCapturePhotoCaptureDelegate {

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        // Burst mode: resume the continuation with DNG data
        if let continuation = burstContinuation {
            burstContinuation = nil
            if let error = error {
                continuation.resume(throwing: error)
            } else if photo.isRawPhoto, let data = photo.fileDataRepresentation() {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: ProcessingError.textureCreationFailed)
            }
            return
        }

        // Quick mode: save the single DNG
        if let error = error {
            Log.export.error("Photo processing error: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.lastSaveError = error.localizedDescription
            }
            return
        }

        Log.export.info("Received photo: isRaw=\(photo.isRawPhoto)")

        if let dngData = photo.fileDataRepresentation() {
            Log.export.info("DNG data: \(dngData.count) bytes")
            saveDNGData(dngData)
        } else {
            Log.export.error("Failed to get DNG file data")
            DispatchQueue.main.async {
                self.lastSaveError = "Failed to encode DNG"
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: Error?) {
        // Burst mode handles completion via continuation — skip here
        guard !isBurstCapturing else { return }

        // Quick mode
        if let error = error {
            Log.export.error("Capture failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.lastSaveError = error.localizedDescription
            }
        } else {
            Log.export.info("DNG capture complete")
        }

        DispatchQueue.main.async {
            self.isCapturing = false
        }
    }
}
