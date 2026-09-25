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
        guard let nsImage = NSImage(contentsOfFile: path),
              let sourceImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let dimension = 120
        guard let context = CGContext(
            data: nil,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
        guard let resizedImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: resizedImage).representation(using: .png, properties: [:])
        #else
        guard let uiImage = UIImage(contentsOfFile: path) else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
        return renderer.pngData { context in
            uiImage.draw(in: CGRect(origin: .zero, size: CGSize(width: 120, height: 120)))
        }
        #endif
    }
}
