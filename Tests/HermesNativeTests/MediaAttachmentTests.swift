import Testing
import Foundation
@testable import HermesNative

@Suite("MediaAttachment")
struct MediaAttachmentTests {

    @Test("Category detects image extensions")
    func categoryImageExtensions() {
        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif"]
        for ext in imageExts {
            let cat = MediaAttachment.Category(ext: ext)
            #expect(cat == .image, "Expected .image for ext '\(ext)', got \(cat)")
        }
    }

    @Test("Category maps unknown extensions to document")
    func categoryDocumentExtensions() {
        let docExts = ["pdf", "txt", "doc", "zip", "mp4", "mp3", "json", ""]
        for ext in docExts {
            let cat = MediaAttachment.Category(ext: ext)
            #expect(cat == .document, "Expected .document for ext '\(ext)', got \(cat)")
        }
    }

    @Test("Category is case-insensitive")
    func categoryCaseInsensitive() {
        #expect(MediaAttachment.Category(ext: "PNG") == .image)
        #expect(MediaAttachment.Category(ext: "Jpg") == .image)
        #expect(MediaAttachment.Category(ext: "PDF") == .document)
    }

    @Test("Category icon is correct")
    func categoryIcons() {
        #expect(MediaAttachment.Category.image.icon == "photo")
        #expect(MediaAttachment.Category.document.icon == "doc")
    }

    @Test("Init extracts filename and extension from path")
    func initFromPath() {
        let attachment = MediaAttachment(path: "/tmp/reports/Q2-summary.pdf")
        #expect(attachment.fileName == "Q2-summary.pdf")
        #expect(attachment.fileExtension == "pdf")
        #expect(attachment.category == .document)
    }

    @Test("Equality is based on id")
    func equalityById() {
        let a = MediaAttachment(path: "/tmp/test.png")
        let b = MediaAttachment(path: "/tmp/test.png")
        let c = a
        #expect(a != b)
        #expect(a == c)
    }

    @Test("Document attachments round-trip through Codable")
    func documentCodableRoundTrip() throws {
        let original = MediaAttachment(path: "/tmp/data.csv")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaAttachment.self, from: encoded)
        #expect(decoded.id == original.id)
        #expect(decoded.fileName == "data.csv")
        #expect(decoded.category == .document)
    }

    @Test("Mixed image and document types are distinct")
    func mixedTypes() {
        let image = MediaAttachment(path: "/tmp/photo.jpg")
        let doc = MediaAttachment(path: "/tmp/readme.txt")
        #expect(image.category == .image)
        #expect(doc.category == .document)
        #expect(image.category != doc.category)
    }
}
