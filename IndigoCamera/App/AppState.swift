import SwiftUI
import Combine

/// Global observable state shared across the app.
final class AppState: ObservableObject {
    @Published var captureSettings = CaptureSettings()
    @Published var isProcessing = false
    @Published var processingProgress: Float = 0
    @Published var lastCapturedImage: UIImage?
    @Published var errorMessage: String?
    @Published var showError = false

    func showError(_ message: String) {
        DispatchQueue.main.async {
            self.errorMessage = message
            self.showError = true
        }
    }
}
