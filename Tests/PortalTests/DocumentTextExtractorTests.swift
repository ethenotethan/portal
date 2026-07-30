import Foundation
import Testing
@testable import Portal

@Suite("Document text extractor")
internal struct DocumentTextExtractorTests {

    // MARK: - isLikelyExtractable (the pure format gate)

    @Test("Text-ish and document formats are worth extracting")
    internal func extractableFormats() {
        for ext in ["txt", "md", "json", "csv", "xml", "log", "swift", "pdf", "rtf", "docx"] {
            #expect(DocumentTextExtractor.isLikelyExtractable(ext), "\(ext) should be extractable")
        }
    }

    @Test("Binary media and archives are not extracted here")
    internal func nonExtractableFormats() {
        for ext in ["png", "jpg", "heic", "zip", "gz", "mp3", "mp4", "mov", "xlsx", "pptx"] {
            #expect(!DocumentTextExtractor.isLikelyExtractable(ext), "\(ext) should not be extractable")
        }
    }

    @Test("The extension gate is case-insensitive")
    internal func gateCaseInsensitive() {
        #expect(DocumentTextExtractor.isLikelyExtractable("TXT"))
        #expect(!DocumentTextExtractor.isLikelyExtractable("PNG"))
    }

    // MARK: - Plain-text extraction from a real temp file

    private func writeTemp(_ contents: String, ext: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("doctest-\(UUID().uuidString).\(ext)")
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    @Test("A UTF-8 text file round-trips through extractText")
    internal func extractsPlainText() throws {
        let body = "hello\nworld"
        let path = try writeTemp(body, ext: "txt")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(DocumentTextExtractor.extractText(path: path, fileExtension: "txt") == body)
    }

    @Test("An unknown extension still extracts as text when it decodes")
    internal func unknownExtensionFallsBackToText() throws {
        let body = "id,name\n1,alice"
        let path = try writeTemp(body, ext: "unknownext")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(DocumentTextExtractor.extractText(path: path, fileExtension: "unknownext") == body)
    }

    @Test("An empty file yields nil, not an empty string")
    internal func emptyFileIsNil() throws {
        let path = try writeTemp("", ext: "txt")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(DocumentTextExtractor.extractText(path: path, fileExtension: "txt") == nil)
    }

    @Test("A missing file yields nil rather than crashing")
    internal func missingFileIsNil() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).txt").path
        #expect(DocumentTextExtractor.extractText(path: path, fileExtension: "txt") == nil)
    }

    // MARK: - Truncation of oversized documents

    @Test("A document over the inline cap is truncated with a marker")
    internal func oversizedIsTruncated() throws {
        let cap = DocumentTextExtractor.maxInlineCharacters
        let body = String(repeating: "a", count: cap + 500)
        let path = try writeTemp(body, ext: "txt")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let out = try #require(DocumentTextExtractor.extractText(path: path, fileExtension: "txt"))
        // Kept the head, appended the omission marker, and dropped the tail.
        #expect(out.hasPrefix(String(repeating: "a", count: 100)))
        #expect(out.contains("document truncated"))
        #expect(out.contains("500 more characters"))
        #expect(out.count < body.count)
    }

    @Test("A document exactly at the cap is not truncated")
    internal func atCapNotTruncated() throws {
        let cap = DocumentTextExtractor.maxInlineCharacters
        let body = String(repeating: "b", count: cap)
        let path = try writeTemp(body, ext: "txt")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let out = DocumentTextExtractor.extractText(path: path, fileExtension: "txt")
        #expect(out == body)
    }
}
