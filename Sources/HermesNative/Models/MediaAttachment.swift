import SwiftUI

/// An image/file attachment that the user is sending with their message.
/// Stored in ChatMessage for display in the user's message bubble.
/// Distinct from FileAttachment which represents attachments RECEIVED from the agent.
struct MediaAttachment: Identifiable, Codable, Equatable {
    let id: UUID
    let path: String        // Local file path after saving to cache
    let fileName: String
    let fileExtension: String
    let category: Category
    var thumbnailData: Data? // Small thumbnail for inline display

    enum Category: String, Codable {
        case image
        case document

        init(ext: String) {
            switch ext.lowercased() {
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif":
                self = .image
            default:
                self = .document
            }
        }

        var icon: String {
            switch self {
            case .image: "photo"
            case .document: "doc"
            }
        }
    }

    init(path: String, thumbnailData: Data? = nil) {
        self.id = UUID()
        self.path = path
        self.fileName = (path as NSString).lastPathComponent
        self.fileExtension = (path as NSString).pathExtension
        self.category = Category(ext: self.fileExtension)
        self.thumbnailData = thumbnailData
    }

    static func == (lhs: MediaAttachment, rhs: MediaAttachment) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Thumbnail Generation

extension MediaAttachment {
    /// Generate a 120×120 thumbnail for display in the input bar and message bubbles.
    static func generateThumbnail(for path: String) -> Data? {
        #if os(macOS)
        guard let nsImage = NSImage(contentsOfFile: path) else { return nil }
        let targetSize = NSSize(width: 120, height: 120)
        let resized = NSImage(size: targetSize)
        resized.lockFocus()
        nsImage.draw(in: NSRect(origin: .zero, size: targetSize),
                     from: NSRect(origin: .zero, size: nsImage.size),
                     operation: .copy,
                     fraction: 1.0)
        if let tiffData = resized.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData) {
            resized.unlockFocus()
            return bitmap.representation(using: .png, properties: [:])
        }
        resized.unlockFocus()
        return nil
        #else
        guard let uiImage = UIImage(contentsOfFile: path) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
        return renderer.pngData { context in
            uiImage.draw(in: CGRect(origin: .zero, size: CGSize(width: 120, height: 120)))
        }
        #endif
    }
}
