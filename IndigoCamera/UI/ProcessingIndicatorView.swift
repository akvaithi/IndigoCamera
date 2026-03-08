import SwiftUI

/// Shows processing progress with a bar and frame count.
struct ProcessingIndicatorView: View {
    let progress: Float

    var body: some View {
        VStack(spacing: 6) {
            Text("Processing...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yellow)
                        .frame(width: geometry.size.width * CGFloat(progress), height: 6)
                        .animation(.easeInOut(duration: 0.2), value: progress)
                }
            }
            .frame(height: 6)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 40)
    }
}
