import SwiftUI

/// Platform-agnostic thumbnail image view.
/// Handles the #if os(macOS)/#else split at the view level rather than inside
/// an `if let` condition, which Swift does not allow.
struct ThumbnailImageView: View {
    let data: Data?
    let fallbackIcon: String

    var body: some View {
        #if os(macOS)
        if let data, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #else
        if let data, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: 16))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #endif
    }
}
