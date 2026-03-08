import SwiftUI

/// Horizontal pill selector for capture modes (Quick / Stack / Super-Res).
struct ModeSelector: View {
    @Binding var selectedMode: CaptureMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CaptureMode.allCases) { mode in
                Button(action: { selectedMode = mode }) {
                    Text(mode.displayName)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selectedMode == mode ? Color.orange : Color.gray.opacity(0.3))
                        .foregroundColor(selectedMode == mode ? .black : .white.opacity(0.7))
                }
            }
        }
        .cornerRadius(6)
    }
}
