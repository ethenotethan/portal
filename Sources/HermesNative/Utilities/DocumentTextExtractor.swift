import Foundation
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Extracts plain text from document files on-device, so a document's content
/// can be embedded directly in a chat prompt without any server round-trip or
/// model-specific file support.
///
/// Returns nil when the file can't be meaningfully turned into text here (e.g.
/// a binary format with no on-device extractor). Callers fall back to uploading
/// the file and referencing its server path instead.
enum DocumentTextExtractor {
    /// Upper bound on extracted characters embedded inline. Very large docs are
    /// truncated (with a marker) so a single attachment can't blow the context
    /// window or the prompt payload.
    static let maxInlineCharacters = 200_000

    /// Attempt to extract text from the file at `path`. Runs synchronous file
    /// I/O — call off the main actor for large files.
    static func extractText(path: String, fileExtension: String) -> String? {
        let ext = fileExtension.lowercased()
        let url = URL(fileURLWithPath: path)

        switch ext {
        case "pdf":
            return truncate(extractPDF(url: url))
        case "rtf", "rtfd":
            return truncate(extractAttributed(url: url))
        case "doc", "docx", "odt", "pages", "wordml":
            // NSAttributedString can read some of these via the system text
            // importers; when it can't it returns nil and we fall back to upload.
            return truncate(extractAttributed(url: url))
        default:
            // Treat anything that decodes as UTF-8/UTF-16 text as a text file
            // (covers txt, md, json, csv, xml, source code, logs, etc.).
            return truncate(extractPlainText(url: url))
        }
    }

    /// True when this extension is worth attempting inline extraction for.
    /// (Images are handled by the vision path, not here.)
    static func isLikelyExtractable(_ fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        let binaryNonText: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif",
            "zip", "tar", "gz", "7z", "rar", "dmg", "iso",
            "mp3", "wav", "ogg", "m4a", "flac", "aac",
            "mp4", "mov", "avi", "mkv", "webm",
            "xls", "xlsx", "ppt", "pptx", // binary office: better handled server-side
        ]
        return !binaryNonText.contains(ext)
    }

    // MARK: - Format-specific extractors

    private static func extractPDF(url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var pieces: [String] = []
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let text = page.string, !text.isEmpty {
                pieces.append(text)
            }
        }
        let joined = pieces.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    private static func extractAttributed(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        #if os(macOS)
        let attr = try? NSAttributedString(data: data, options: [:], documentAttributes: nil)
        #else
        let attr = try? NSAttributedString(data: data, options: [:], documentAttributes: nil)
        #endif
        let text = attr?.string ?? ""
        return text.isEmpty ? nil : text
    }

    private static func extractPlainText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        if let latin1 = String(data: data, encoding: .isoLatin1) { return latin1 }
        return nil
    }

    private static func truncate(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.count > maxInlineCharacters else { return text }
        let head = text.prefix(maxInlineCharacters)
        return String(head) + "\n\n[… document truncated — \(text.count - maxInlineCharacters) more characters omitted …]"
    }
}
