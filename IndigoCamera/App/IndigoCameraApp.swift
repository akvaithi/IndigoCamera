import SwiftUI

@main
struct IndigoCameraApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environmentObject(appState)
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
