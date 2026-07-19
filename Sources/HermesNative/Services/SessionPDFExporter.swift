#if os(macOS)
import SwiftUI
import AppKit
import SwiftMath
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SessionPDFExporter")

/// Renders a chat session — user messages plus all agent output, including
/// native Swift Charts and mermaid diagrams — into a paginated US-Letter PDF
/// that mirrors the in-app dark theme, so a session can be shared as-is.
///
/// Mermaid diagrams are pre-rendered to images before the ImageRenderer pass:
/// ImageRenderer is synchronous and cannot wait for a view's async rendering,
/// so anything async (the native BeautifulMermaid layout or the WKWebView
/// mermaid.js fallback) has to resolve first.
@MainActor
enum SessionPDFExporter {

    private static let pageSize = CGSize(width: 612, height: 792) // US Letter
    private static let margin: CGFloat = 40
    private static var contentWidth: CGFloat { pageSize.width - margin * 2 }
    private static var contentHeight: CGFloat { pageSize.height - margin * 2 }
    private static let rowSpacing: CGFloat = 12

    /// Render `messages` to PDF data. Returns nil for an empty session or if
    /// the PDF context cannot be created.
    static func export(messages: [ChatMessage], title: String, assistantName: String) async -> Data? {
        guard !messages.isEmpty else { return nil }
        let diagramImages = await renderDiagramImages(in: messages)
        let rows = buildRows(
            messages: messages,
            title: title,
            assistantName: assistantName,
            diagramImages: diagramImages
        )
        guard !rows.isEmpty else { return nil }
        return renderPDF(rows: rows, title: title)
    }

    // MARK: - Diagram pre-rendering

    private static func renderDiagramImages(in messages: [ChatMessage]) async -> [String: PlatformImage] {
        var images: [String: PlatformImage] = [:]
        for message in messages where message.role == .assistant {
            for block in MarkdownParser.parse(message.contentWithoutAttachments) {
                guard case .codeBlock(let language, let code) = block,
                      MarkdownParser.isDiagramLanguage(language),
                      images[code] == nil
                else { continue }
                if let image = await MermaidExportRenderer.renderImage(source: code) {
                    images[code] = image
                } else {
                    log.warning("PDF export: diagram failed to render, falling back to source text")
                }
            }
        }
        return images
    }

    // MARK: - Row building

    private static func buildRows(
        messages: [ChatMessage],
        title: String,
        assistantName: String,
        diagramImages: [String: PlatformImage]
    ) -> [AnyView] {
        var rows: [AnyView] = []
        rows.append(AnyView(ExportTitleHeader(title: title, messageCount: messages.count)))

        for message in messages {
            let content = message.contentWithoutAttachments
            let isUser = message.role == .user
            rows.append(AnyView(ExportRoleHeader(
                label: isUser ? "You" : assistantName,
                isUser: isUser
            )))

            if isUser {
                if !content.isEmpty {
                    rows.append(AnyView(ExportUserText(text: content)))
                }
            } else {
                for block in MarkdownParser.parse(content) {
                    rows.append(AnyView(ExportBlockView(block: block, diagramImages: diagramImages)))
                }
                if !message.toolCalls.isEmpty {
                    rows.append(AnyView(ExportToolCalls(tools: message.toolCalls)))
                }
            }

            for attachment in message.attachments where attachment.category == .image {
                if let image = loadImage(for: attachment) {
                    rows.append(AnyView(ExportImageRow(image: image, caption: attachment.fileName)))
                }
            }
            for attachment in message.userAttachments {
                if let data = attachment.thumbnailData, let image = NSImage(data: data) {
                    rows.append(AnyView(ExportImageRow(image: image, caption: attachment.fileName)))
                }
            }
        }
        return rows
    }

    private static func loadImage(for attachment: FileAttachment) -> NSImage? {
        switch attachment.source {
        case .local(let path):
            return NSImage(contentsOfFile: path)
        case .remote:
            if case .ready(let data) = attachment.downloadState {
                return NSImage(data: data)
            }
            return nil
        }
    }

    // MARK: - PDF rendering

    private static func renderPDF(rows: [AnyView], title: String) -> Data? {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        let metadata: [CFString: Any] = [
            kCGPDFContextTitle: title,
            kCGPDFContextCreator: "Hermes Native",
        ]
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata as CFDictionary)
        else {
            log.error("PDF export: failed to create PDF context")
            return nil
        }

        var yOffset: CGFloat = 0
        var pageOpen = false

        func beginPage() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(NSColor(Theme.background).cgColor)
            ctx.fill(mediaBox)
            pageOpen = true
            yOffset = 0
        }
        func endPage() {
            guard pageOpen else { return }
            ctx.endPDFPage()
            pageOpen = false
        }

        for row in rows {
            let view = row
                .frame(width: contentWidth, alignment: .leading)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: contentWidth, height: nil)

            // Measurement pass: the render callback hands us the laid-out size
            // and a draw closure; skipping the closure measures without drawing.
            var rowSize: CGSize = .zero
            renderer.render { size, _ in rowSize = size }
            guard rowSize.height > 0 else { continue }

            // Rows taller than a page (e.g. a large diagram) are scaled down
            // to fit one page rather than being clipped mid-content.
            let scale = min(1, contentHeight / rowSize.height)
            let drawHeight = rowSize.height * scale

            if !pageOpen || yOffset + drawHeight > contentHeight {
                endPage()
                beginPage()
            }

            renderer.render { size, draw in
                ctx.saveGState()
                ctx.translateBy(x: margin, y: pageSize.height - margin - yOffset - size.height * scale)
                ctx.scaleBy(x: scale, y: scale)
                draw(ctx)
                ctx.restoreGState()
            }
            yOffset += drawHeight + rowSpacing
        }

        endPage()
        ctx.closePDF()
        return pdfData as Data
    }
}

// MARK: - Export Row Views

private struct ExportTitleHeader: View {
    let title: String
    let messageCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.primary)
            Text("Exported from Hermes · \(Date().formatted(date: .abbreviated, time: .shortened)) · \(messageCount) message\(messageCount == 1 ? "" : "s")")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Rectangle()
                .fill(Theme.accent.opacity(0.4))
                .frame(height: 2)
                .padding(.top, 6)
        }
    }
}

private struct ExportRoleHeader: View {
    let label: String
    let isUser: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isUser ? Theme.secondary : Theme.accent)
            Rectangle()
                .fill(Theme.border)
                .frame(height: 0.5)
        }
        .padding(.top, 10)
    }
}

private struct ExportUserText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.primary)
            .padding(.horizontal, Theme.bubblePaddingH)
            .padding(.vertical, Theme.bubblePaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
    }
}

/// Dispatches a parsed markdown block to an export-safe view. Mirrors
/// MarkdownContentView's dispatch, swapping anything interactive or async
/// (webviews, scroll views, collapsed tables) for static equivalents.
private struct ExportBlockView: View {
    let block: MarkdownBlock
    let diagramImages: [String: PlatformImage]

    var body: some View {
        switch block {
        case .codeBlock(let language, let code):
            if MarkdownParser.isChartLanguage(language) {
                // interactive: false — the zoomed chart plot is a scroll view,
                // which ImageRenderer rasterizes as an empty box; export always
                // draws the full domain with all series visible.
                NativeChartView(json: code, isStreaming: false, interactive: false)
            } else if MarkdownParser.isDiagramLanguage(language) {
                if let image = diagramImages[code] {
                    ExportImageRow(image: image, caption: MermaidDiagramView.diagramTypeLabel(for: code))
                } else {
                    ExportCodeText(language: language, code: code)
                }
            } else if MarkdownParser.isDiffLanguage(language) {
                // Static line list — DiffBlockView's horizontal ScrollView
                // rasterizes as an empty box under ImageRenderer.
                ExportDiffView(code: code)
            } else if MarkdownParser.isTreeLanguage(language) {
                // Trees keep their ASCII form in print; the interactive
                // disclosure UI has no meaning on paper.
                ExportCodeText(language: "", code: code)
            } else if MarkdownParser.isStatsLanguage(language) {
                // Tile grid + Path sparklines rasterize fine (no scroll
                // views, no representables) — reuse the live view.
                StatTilesView(json: code, isStreaming: false)
            } else if MarkdownParser.isGraphLanguage(language) {
                // Canvas + circles + text — no representables; the static
                // layout is deterministic, so print matches screen.
                NetworkGraphView(json: code, isStreaming: false)
            } else {
                ExportCodeText(language: language, code: code)
            }
        case .heading(let level, let content):
            HeadingView(level: level, content: content)
        case .listItem(let index, let content, let isOrdered):
            ListItemView(index: index, content: content, isOrdered: isOrdered)
        case .blockquote(let content):
            BlockQuoteView(content: content)
        case .horizontalRule:
            Rectangle()
                .fill(Theme.border)
                .frame(height: 0.5)
                .padding(.vertical, 4)
        case .table(let headers, let rows):
            ExportTableView(headers: headers, rows: rows)
        case .paragraph(let content):
            MarkdownText(text: content)
                .foregroundStyle(Theme.primary)
                .lineSpacing(3)
        case .mathBlock(let tex):
            ExportMathView(tex: tex)
        }
    }
}

/// Typeset math for PDF export. MathView wraps MTMathUILabel — an
/// NSViewRepresentable, which ImageRenderer rasterizes as an EMPTY box
/// (same limitation as scroll views). SwiftMath's MTMathImage renders the
/// same typesetting offscreen to a bitmap, which ImageRenderer embeds fine;
/// unparseable TeX falls back to the monospaced source.
private struct ExportMathView: View {
    let tex: String

    var body: some View {
        if let image = Self.typeset(tex) {
            // Half-size frame: typeset at 2x for print resolution.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: image.size.width / 2, height: image.size.height / 2)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        } else {
            ExportCodeText(language: "math", code: tex)
        }
    }

    @MainActor
    static func typeset(_ tex: String) -> PlatformImage? {
        var renderer = MTMathImage(
            latex: tex,
            fontSize: 32,   // 2x the on-screen 16pt for print resolution
            textColor: mtColor(Theme.primary),
            labelMode: .display,
            textAlignment: .left
        )
        renderer.contentInsets = MTEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        let (error, image) = renderer.asImage()
        guard error == nil, let image else { return nil }
        return image
    }
}

/// Static diff for PDF export: same line classification/tinting as
/// DiffBlockView, laid out directly (no ScrollView) so lines wrap.
private struct ExportDiffView: View {
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(DiffLine.parse(code)) { line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(color(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(for: line.kind))
            }
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        case .hunk: return Theme.accent
        case .fileHeader: return Theme.secondary
        case .context: return Theme.primary.opacity(0.85)
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return .green.opacity(0.10)
        case .deletion: return .red.opacity(0.10)
        case .hunk: return Theme.accent.opacity(0.06)
        case .fileHeader, .context: return .clear
        }
    }
}

/// Static table for PDF export. TableView wraps its content in a horizontal
/// ScrollView, which ImageRenderer rasterizes as an empty box — so lay the
/// grid out directly, letting cells wrap instead of scrolling.
private struct ExportTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    cell(text: header, isHeader: true)
                }
            }
            .background(Theme.accent.opacity(0.08))

            ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        cell(text: value, isHeader: false)
                    }
                }
                .background(rowIndex % 2 == 0 ? Theme.background : Theme.surface.opacity(0.3))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func cell(text: String, isHeader: Bool) -> some View {
        MarkdownText(
            text: text,
            baseColor: isHeader ? Theme.accent : nil,
            baseFont: isHeader ? .system(size: 11, weight: .bold, design: .monospaced) : .system(size: 12)
        )
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, isHeader ? 8 : 7)
    }

    private var normalizedRows: [[String]] {
        rows.map { row in
            let missing = max(0, headers.count - row.count)
            return Array((row + Array(repeating: "", count: missing)).prefix(headers.count))
        }
    }
}

/// Code block without the horizontal ScrollView or copy button — long lines
/// wrap so nothing is clipped on the page.
private struct ExportCodeText: View {
    let language: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
            }
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}

private struct ExportImageRow: View {
    let image: NSImage
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border, lineWidth: 0.5)
                )
            Text(caption)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.secondary)
        }
    }
}

private struct ExportToolCalls: View {
    let tools: [ToolCallRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Tool calls (\(tools.count))")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            ForEach(tools) { tool in
                HStack(alignment: .top, spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.accent.opacity(0.85))
                    if let summary = tool.summary ?? tool.context, !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
#endif
