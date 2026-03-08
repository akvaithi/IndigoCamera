import AVFoundation
import CoreVideo
import Metal
import Combine

/// Manages the AVCaptureSession, camera input/output, and continuous frame delivery.
final class CameraManager: NSObject, ObservableObject {
    // MARK: - Published State

    @Published var isSessionRunning = false
    @Published var isCameraAuthorized = false
    @Published var currentISO: Float = 100
    @Published var currentExposureDuration: Double = 1.0 / 60.0
    @Published var currentFocusPosition: Float = 0.5

    // MARK: - Capture Session

    let captureSession = AVCaptureSession()
    let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var cameraDevice: AVCaptureDevice?
    private var deviceInput: AVCaptureDeviceInput?

    // MARK: - Queues

    private let sessionQueue = DispatchQueue(label: "com.indigo.session")
    private let videoOutputQueue = DispatchQueue(label: "com.indigo.videoOutput",
                                                  qos: .userInitiated)

    // MARK: - Dependencies

    let frameRingBuffer: FrameRingBuffer
    private(set) var configurator: CameraConfigurator?

    // MARK: - Init

    init(frameRingBuffer: FrameRingBuffer) {
        self.frameRingBuffer = frameRingBuffer
        super.init()
    }

    // MARK: - Authorization

    func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.isCameraAuthorized = true }
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { self?.isCameraAuthorized = granted }
                if granted { self?.configure() }
            }
        default:
            DispatchQueue.main.async { self.isCameraAuthorized = false }
        }
    }

    // MARK: - Session Configuration

    func configure() {
        sessionQueue.async { [weak self] in
            self?.configureSession()
        }
    }

    private func configureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        // 1. Find the back wide-angle camera
        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera, for: .video, position: .back
        ) else {
            Log.camera.error("No back camera found")
            captureSession.commitConfiguration()
            return
        }
        self.cameraDevice = camera

        // 2. Add camera input
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                self.deviceInput = input
            }
        } catch {
            Log.camera.error("Failed to create camera input: \(error.localizedDescription)")
            captureSession.commitConfiguration()
            return
        }

        // 3. Configure video output for continuous frames
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoOutputQueue)

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }

        // 4. Add photo output for RAW/DNG capture
        if captureSession.canAddOutput(photoOutput) {
            captureSession.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        // 5. The .photo preset selects a format that supports RAW capture.
        //    Don't override it — changing the active format can break RAW support.
        //    Log the selected format and video output dimensions for debugging.
        let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        Log.camera.info("Active format: \(dims.width)x\(dims.height)")
        Log.camera.info("RAW formats available: \(self.photoOutput.availableRawPhotoPixelFormatTypes.count)")

        captureSession.commitConfiguration()

        // 6. Create configurator
        self.configurator = CameraConfigurator(device: camera)

        // 7. Explicitly set full auto mode
        configurator?.setAutoExposure()
        configurator?.setAutoFocus()
        configurator?.setAutoWhiteBalance()

        // 8. Start the session
        captureSession.startRunning()
        DispatchQueue.main.async {
            self.isSessionRunning = self.captureSession.isRunning
        }

        Log.camera.info("Camera session started in full auto mode")
    }

    // MARK: - Session Control

    func startSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = self?.captureSession.isRunning ?? false
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async {
                self?.isSessionRunning = false
            }
        }
    }

    func updateCurrentValues() {
        guard let device = cameraDevice else { return }
        DispatchQueue.main.async {
            self.currentISO = device.iso
            self.currentExposureDuration = device.exposureDuration.seconds
            self.currentFocusPosition = device.lensPosition
        }
    }
}

// MARK: - Video Data Output Delegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Insert every frame into the ring buffer for zero shutter lag
        frameRingBuffer.append(sampleBuffer)

        // Periodically update displayed values
        updateCurrentValues()
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        Log.camera.debug("Frame dropped")
    }
}
