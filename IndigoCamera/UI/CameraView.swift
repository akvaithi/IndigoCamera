import SwiftUI
import Combine

/// Main camera screen - DSLR-like DNG-only workflow.
/// Supports Quick (single DNG), Stack (multi-frame merged), and Super-Res modes.
struct CameraView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var cameraHolder = CameraManagerHolder()
    @StateObject private var captureHolder = CaptureCoordinatorHolder()
    @State private var captureMode: CaptureMode = .quick
    @State private var showReview = false
    @State private var isSetUp = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top bar
                topBar

                // Camera Preview (4:3 aspect fit, full frame)
                if let manager = cameraHolder.manager, manager.isCameraAuthorized {
                    CameraPreviewView(session: manager.captureSession)
                        .aspectRatio(3.0 / 4.0, contentMode: .fit)
                        .clipped()
                } else {
                    ZStack {
                        Color.black
                        VStack(spacing: 16) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.gray)
                            Text("Camera access required")
                                .foregroundColor(.gray)
                            Text("Go to Settings > Privacy > Camera")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                }

                Spacer(minLength: 0)

                // Error message
                if let error = captureHolder.coordinator?.lastSaveError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(6)
                }

                // Processing indicator
                if captureHolder.coordinator?.isCapturing == true {
                    if captureMode == .quick {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text("Capturing DNG...")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                        .padding(8)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                    } else {
                        ProcessingIndicatorView(
                            progress: captureHolder.coordinator?.processingProgress ?? 0
                        )
                    }
                }

                // Bottom bar
                bottomBar
            }
        }
        .onAppear {
            if !isSetUp {
                setupCamera()
                isSetUp = true
            }
        }
        .sheet(isPresented: $showReview) {
            if let image = captureHolder.coordinator?.lastCapturedImage {
                ReviewView(image: image)
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            captureHolder.coordinator?.handleMemoryWarning()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // RAW badge
            Text("RAW")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange)
                .cornerRadius(6)

            Spacer()

            // Frame count picker (only in multi-frame modes)
            if captureMode != .quick {
                FrameCountPicker(frameCount: $appState.captureSettings.frameCount)
            }

            Spacer()

            // Live exposure readout
            if let manager = cameraHolder.manager {
                Text("ISO \(Int(manager.currentISO))  \(formatShutter(manager.currentExposureDuration))")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            // Last photo thumbnail
            Button(action: {
                if captureHolder.coordinator?.lastCapturedImage != nil {
                    showReview = true
                }
            }) {
                if let image = captureHolder.coordinator?.lastCapturedImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 50, height: 50)
                        .cornerRadius(8)
                        .clipped()
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 50, height: 50)
                }
            }

            Spacer()

            // Shutter button
            ShutterButton(
                isProcessing: captureHolder.coordinator?.isCapturing ?? false
            ) {
                captureHolder.coordinator?.capturePhoto(
                    mode: captureMode,
                    settings: appState.captureSettings
                )
            }

            Spacer()

            // Mode selector
            ModeSelector(selectedMode: $captureMode)
        }
        .padding(.horizontal, 30)
        .padding(.bottom, 20)
        .padding(.top, 8)
    }

    // MARK: - Setup

    private func setupCamera() {
        let buffer = FrameRingBuffer(capacity: 16)  // 16 for super-res mode
        let manager = CameraManager(frameRingBuffer: buffer)
        cameraHolder.setManager(manager)

        do {
            let metalContext = try MetalContext()
            let coordinator = CaptureCoordinator(cameraManager: manager, metalContext: metalContext)
            captureHolder.setCoordinator(coordinator)
        } catch {
            Log.metal.error("MetalContext init failed: \(error)")
        }

        manager.checkAuthorization()

        Task {
            _ = await OutputEncoder.requestPhotoLibraryAccess()
        }
    }

    private func formatShutter(_ seconds: Double) -> String {
        if seconds >= 1.0 {
            return String(format: "%.1fs", seconds)
        } else if seconds > 0 {
            let denom = Int(round(1.0 / seconds))
            return "1/\(denom)"
        }
        return "--"
    }
}

// MARK: - Observable Holders

class CameraManagerHolder: ObservableObject {
    @Published var manager: CameraManager?
    private var cancellable: AnyCancellable?

    func setManager(_ mgr: CameraManager) {
        cancellable = mgr.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        self.manager = mgr
    }
}

class CaptureCoordinatorHolder: ObservableObject {
    @Published var coordinator: CaptureCoordinator?
    private var cancellable: AnyCancellable?

    func setCoordinator(_ coord: CaptureCoordinator) {
        cancellable = coord.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        self.coordinator = coord
    }
}
