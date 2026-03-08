import SwiftUI

/// The shutter button with a visual indicator for processing state.
struct ShutterButton: View {
    let isProcessing: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: {
            guard !isProcessing else { return }
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            action()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)

                // Inner circle
                Circle()
                    .fill(isProcessing ? Color.gray : Color.white)
                    .frame(width: 60, height: 60)
                    .scaleEffect(isPressed ? 0.85 : 1.0)

                // Processing spinner
                if isProcessing {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
            }
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(isProcessing)
        .accessibilityLabel("Take photo")
    }
}

/// Custom button style that animates the press state.
struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
