import Foundation
import CoreText
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// PDF rendering for session exports. Generated FROM the markdown document
/// (not by screenshotting views): the markdown is converted to a styled
/// NSAttributedString and paginated with CoreText — the same code path on
/// macOS and iOS, printable black-on-white, US Letter with margins and a
/// per-page header (session title + page number).
extension SessionExporter {

    private enum Page {
        static let size = CGSize(width: 612, height: 792) // US Letter
        static let margin: CGFloat = 54
        static let headerHeight: CGFloat = 24
        static var contentRect: CGRect {
            CGRect(
                x: margin,
                y: margin,
                width: size.width - margin * 2,
                height: size.height - margin * 2 - headerHeight
            )
        }
    }

    /// Render a session-export markdown document to PDF data.
    /// Returns nil only if the PDF context cannot be created.
    static func pdf(markdown: String, title: String) -> Data? {
        let attributed = attributedDocument(from: markdown)
        guard attributed.length > 0 else { return nil }

        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Page.size)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "Hermes Native",
        ]
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary)
        else { return nil }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        var pageNumber = 1
        let path = CGPath(rect: Page.contentRect, transform: nil)

        while location < attributed.length {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(mediaBox)

            drawHeader(in: ctx, title: title, pageNumber: pageNumber)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: location, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()

            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break } // safety: avoid infinite loop
            location += visible.length
            pageNumber += 1
        }
        ctx.closePDF()
        return data as Data
    }

    private static func drawHeader(in ctx: CGContext, title: String, pageNumber: Int) {
        let gray = CGColor(gray: 0.45, alpha: 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font(size: 9, weight: .medium),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): gray,
        ]
        let headerY = Page.size.height - Page.margin - 4

        let titleLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: title, attributes: attrs)
        )
        ctx.textPosition = CGPoint(x: Page.margin, y: headerY)
        CTLineDraw(titleLine, ctx)

        let pageLine = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Page \(pageNumber)", attributes: attrs)
        )
        let pageWidth = CTLineGetTypographicBounds(pageLine, nil, nil, nil)
        ctx.textPosition = CGPoint(
            x: Page.size.width - Page.margin - CGFloat(pageWidth),
            y: headerY
        )
        CTLineDraw(pageLine, ctx)

        ctx.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: Page.margin, y: headerY - 6))
        ctx.addLine(to: CGPoint(x: Page.size.width - Page.margin, y: headerY - 6))
        ctx.strokePath()
    }

    // MARK: - Markdown → NSAttributedString

    /// Line-based markdown styling: headings, fenced code (monospaced),
    /// blockquotes (gray), horizontal rules. Inline emphasis inside normal
    /// paragraphs is resolved via Foundation's markdown parser; code fences
    /// are preserved verbatim. Modest typography by design — the markdown
    /// file remains the canonical artifact.
    static func attributedDocument(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let black = CGColor(gray: 0.1, alpha: 1)
        let gray = CGColor(gray: 0.45, alpha: 1)

        var inCodeFence = false
        var fenceMarker = ""

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if inCodeFence {
                if trimmed == fenceMarker {
                    inCodeFence = false
                } else {
                    result.append(NSAttributedString(
                        string: line + "\n",
                        attributes: [.font: monoFont(size: 9), colorKey: black]
                    ))
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                inCodeFence = true
                fenceMarker = String(trimmed.prefix(while: { $0 == "`" }))
                continue
            }

            // <details>/<summary> wrappers have no PDF meaning — keep the label.
            if trimmed == "<details>" || trimmed == "</details>" { continue }
            if trimmed.hasPrefix("<summary>") {
                let label = trimmed
                    .replacingOccurrences(of: "<summary>", with: "")
                    .replacingOccurrences(of: "</summary>", with: "")
                result.append(NSAttributedString(
                    string: label + "\n",
                    attributes: [.font: font(size: 10, weight: .semibold), colorKey: gray]
                ))
                continue
            }

            if trimmed == "---" || trimmed == "***" {
                result.append(NSAttributedString(
                    string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n",
                    attributes: [.font: font(size: 10, weight: .regular), colorKey: gray]
                ))
                continue
            }

            if let (level, text) = headingComponents(of: trimmed) {
                let sizes: [CGFloat] = [18, 15, 13, 12, 11, 11]
                result.append(NSAttributedString(
                    string: text + "\n",
                    attributes: [
                        .font: font(size: sizes[level - 1], weight: .bold),
                        colorKey: black,
                    ]
                ))
                continue
            }

            if trimmed.hasPrefix(">") {
                let text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                result.append(NSAttributedString(
                    string: text + "\n",
                    attributes: [.font: font(size: 10, weight: .regular), colorKey: gray]
                ))
                continue
            }

            result.append(paragraph(line, colorKey: colorKey, color: black))
        }
        return result
    }

    private static func headingComponents(of line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" })
        guard hashes.count <= 6 else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.hasPrefix(" ") else { return nil }
        return (hashes.count, rest.trimmingCharacters(in: .whitespaces))
    }

    /// A body line: resolve inline markdown (bold/italic/code) when it parses,
    /// otherwise keep the raw text.
    private static func paragraph(
        _ line: String,
        colorKey: NSAttributedString.Key,
        color: CGColor
    ) -> NSAttributedString {
        let bodyFont = font(size: 10, weight: .regular)
        guard let parsed = try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: line + "\n", attributes: [.font: bodyFont, colorKey: color])
        }
        let rendered = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            let intent = (value as? NSNumber).map {
                InlinePresentationIntent(rawValue: $0.uintValue)
            } ?? (value as? InlinePresentationIntent) ?? []
            let lineFont: PlatformFont
            if intent.contains(.code) {
                lineFont = monoFont(size: 9)
            } else if intent.contains(.stronglyEmphasized) {
                lineFont = font(size: 10, weight: .semibold)
            } else {
                lineFont = bodyFont
            }
            rendered.addAttribute(.font, value: lineFont, range: range)
        }
        // Runs without any intent still need the body font.
        rendered.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil {
                rendered.addAttribute(.font, value: bodyFont, range: range)
            }
        }
        rendered.addAttribute(colorKey, value: color, range: full)
        rendered.append(NSAttributedString(string: "\n", attributes: [.font: bodyFont, colorKey: color]))
        return rendered
    }

    // MARK: - Fonts

    #if os(macOS)
    private typealias PlatformFont = NSFont
    private static func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
    private static func monoFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    #else
    private typealias PlatformFont = UIFont
    private static func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }
    private static func monoFont(size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    #endif
}
