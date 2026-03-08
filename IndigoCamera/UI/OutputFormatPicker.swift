import SwiftUI

/// Toggle for output format: JPEG, DNG, or both.
struct OutputFormatPicker: View {
    @Binding var outputJPEG: Bool
    @Binding var outputDNG: Bool

    var body: some View {
        HStack(spacing: 4) {
            // JPEG toggle
            Button(action: {
                outputJPEG = true
                // Ensure at least one format is selected
                if !outputDNG { outputJPEG = true }
            }) {
                Text("JPG")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(outputJPEG ? Color.white : Color.gray.opacity(0.3))
                    .foregroundColor(outputJPEG ? .black : .white.opacity(0.6))
                    .cornerRadius(4)
            }

            // DNG toggle
            Button(action: {
                outputDNG.toggle()
                // Ensure at least one format is selected
                if !outputDNG && !outputJPEG { outputJPEG = true }
            }) {
                Text("DNG")
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(outputDNG ? Color.orange : Color.gray.opacity(0.3))
                    .foregroundColor(outputDNG ? .black : .white.opacity(0.6))
                    .cornerRadius(4)
            }
        }
    }
}
