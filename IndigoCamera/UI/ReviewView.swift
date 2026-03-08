import SwiftUI

/// Simple review screen to display the last captured photo.
struct ReviewView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: Image(uiImage: image),
                              preview: SharePreview("Indigo Photo",
                                                     image: Image(uiImage: image)))
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
