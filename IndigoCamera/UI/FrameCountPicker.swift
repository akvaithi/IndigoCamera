import SwiftUI

/// Picker for the number of frames to capture and merge.
struct FrameCountPicker: View {
    @Binding var frameCount: Int

    private let options = [1, 2, 4, 8, 16]

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { count in
                Button(action: { frameCount = count }) {
                    HStack {
                        Text("\(count) frame\(count == 1 ? "" : "s")")
                        if frameCount == count {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 12))
                Text("\(frameCount)")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.gray.opacity(0.5))
            .foregroundColor(.white)
            .cornerRadius(6)
        }
    }
}
