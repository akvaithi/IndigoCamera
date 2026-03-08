import UIKit
import Photos
import AVFoundation
import CoreImage

/// Handles encoding and saving the final output in JPEG and/or DNG format.
final class OutputEncoder {
    private let ciContext: CIContext

    init(metalDevice: MTLDevice) {
        self.ciContext = CIContext(mtlDevice: metalDevice)
    }

    // MARK: - JPEG Export

    /// Encode a UIImage as JPEG data.
    func encodeJPEG(image: UIImage, quality: CGFloat = 0.92) -> Data? {
        return image.jpegData(compressionQuality: quality)
    }

    /// Save JPEG data to the Photos library.
    func saveJPEGToLibrary(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
        Log.export.info("JPEG saved to Photos library")
    }

    /// Save a UIImage directly to the Photos library.
    func saveImageToLibrary(image: UIImage) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
        Log.export.info("Image saved to Photos library")
    }

    // MARK: - DNG Export

    /// Capture a single-frame RAW DNG using AVCapturePhotoOutput.
    /// This is the simplest approach -- uses Apple's built-in DNG writer.
    func captureRAWDNG(photoOutput: AVCapturePhotoOutput,
                       completion: @escaping (Data?) -> Void) {
        // Find an available RAW format
        guard let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first else {
            Log.export.error("RAW capture not available on this device")
            completion(nil)
            return
        }

        let settings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        settings.flashMode = .off

        let delegate = DNGCaptureDelegate { dngData in
            completion(dngData)
        }

        // Hold a strong reference to the delegate
        objc_setAssociatedObject(photoOutput, "dngDelegate", delegate,
                                  .OBJC_ASSOCIATION_RETAIN)
        photoOutput.capturePhoto(with: settings, delegate: delegate)
    }

    /// Save DNG data to the Photos library.
    func saveDNGToLibrary(data: Data) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = "com.adobe.raw-image"
            request.addResource(with: .photo, data: data, options: options)
        }
        Log.export.info("DNG saved to Photos library")
    }

    // MARK: - Photo Library Authorization

    static func requestPhotoLibraryAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return status == .authorized || status == .limited
    }
}

// MARK: - DNG Capture Delegate

/// Internal delegate for single-frame RAW DNG capture.
private class DNGCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let onComplete: (Data?) -> Void

    init(onComplete: @escaping (Data?) -> Void) {
        self.onComplete = onComplete
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        if let error = error {
            Log.export.error("DNG capture error: \(error.localizedDescription)")
            onComplete(nil)
            return
        }
        let data = photo.fileDataRepresentation()
        onComplete(data)
    }
}
