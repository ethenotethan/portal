import SwiftUI
import WebKit

/// Parses and renders markdown content in a SwiftUI view.
/// Uses Apple's built-in AttributedString(markdown:) for inline formatting
/// and custom block parsing for code blocks, headings, lists, etc.
struct MarkdownContentView: View {
    let text: String
    let isStreaming: Bool

    init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .codeBlock(let language, let code):
                    if language == "mermaid" {
                        MermaidDiagramView(mermaidCode: code)
                            .frame(minHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
                            )
                        OpenableBlockChip(label: "Open Diagram", language: "mermaid", content: code)
                    } else if language == "html" {
                        CodeBlockView(language: language, code: code)
                        OpenableBlockChip(label: "Open Page", language: "html", content: code)
                    } else {
                        CodeBlockView(language: language, code: code)
                    }
                case .heading(let level, let content):
                    HeadingView(level: level, content: content)
                case .listItem(let index, let content, let isOrdered):
                    ListItemView(index: index, content: content, isOrdered: isOrdered)
                case .blockquote(let content):
                    BlockQuoteView(content: content)
                case .horizontalRule:
                    Divider().padding(.vertical, 2)
                case .table(let headers, let rows):
                    TableView(headers: headers, rows: rows)
                case .paragraph(let content):
                    MarkdownText(text: content)
                }
            }
        }
    }

    private var blocks: [MarkdownBlock] {
        MarkdownParser.parse(text)
    }
}

// MARK: - Block Types

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, content: String)
    case codeBlock(language: String, code: String)
    case listItem(index: Int, content: String, isOrdered: Bool)
    case blockquote(content: String)
    case horizontalRule
    case table(headers: [String], rows: [[String]])
}

// MARK: - Parser

struct MarkdownParser {
    static func parse(_ input: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = input.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if line.hasPrefix("```") {
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                let code = codeLines.joined(separator: "\n")
                if !code.isEmpty {
                    blocks.append(.codeBlock(language: language, code: code))
                }
                continue
            }

            // Indented code block (4 spaces or tab)
            if line.hasPrefix("    ") || line.hasPrefix("\t") {
                var codeLines: [String] = []
                while i < lines.count && (lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t")) {
                    codeLines.append(String(lines[i].dropFirst(lines[i].hasPrefix("    ") ? 4 : 1)))
                    i += 1
                }
                let code = codeLines.joined(separator: "\n")
                if !code.isEmpty {
                    blocks.append(.codeBlock(language: "", code: code))
                }
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // Heading
            if line.hasPrefix("#") {
                let hashCount = line.prefix(while: { $0 == "#" }).count
                if hashCount >= 1 && hashCount <= 6 {
                    let content = String(line.dropFirst(hashCount))
                        .trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: hashCount, content: content))
                    i += 1
                    continue
                }
            }

            // Block quote
            if line.hasPrefix("> ") || line == ">" {
                var quoteLines: [String] = []
                while i < lines.count && (lines[i].hasPrefix("> ") || lines[i] == ">") {
                    let content = lines[i].hasPrefix("> ")
                        ? String(lines[i].dropFirst(2))
                        : ""
                    quoteLines.append(content)
                    i += 1
                }
                let content = quoteLines.joined(separator: "\n")
                if !content.isEmpty {
                    blocks.append(.blockquote(content: content))
                }
                continue
            }

            // Unordered list
            if isUnorderedListItem(trimmed) {
                var listIndex = 0
                while i < lines.count && isUnorderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let content = stripUnorderedPrefix(lines[i])
                    blocks.append(.listItem(index: listIndex, content: content, isOrdered: false))
                    listIndex += 1
                    i += 1
                }
                continue
            }

            // Ordered list
            if isOrderedListItem(trimmed) {
                while i < lines.count && isOrderedListItem(lines[i].trimmingCharacters(in: .whitespaces)) {
                    let (num, content) = stripOrderedPrefix(lines[i])
                    blocks.append(.listItem(index: num, content: content, isOrdered: true))
                    i += 1
                }
                continue
            }

            // GFM table
            if isTableRow(trimmed) && i + 1 < lines.count && isTableDelimiter(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                let headers = parseTableRowCells(trimmed)
                i += 1
                // skip delimiter row
                i += 1
                var rows: [[String]] = []
                while i < lines.count && isTableRow(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(parseTableRowCells(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            // Empty line — skip
            if trimmed.isEmpty {
                i += 1
                continue
            }

            // Paragraph — collect consecutive non-empty, non-block lines
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { break }
                if l.hasPrefix("```") || l.hasPrefix("#") || l.hasPrefix("> ") ||
                   l.hasPrefix("    ") || l.hasPrefix("\t") ||
                   isUnorderedListItem(t) || isOrderedListItem(t) ||
                   isHorizontalRule(t) {
                    break
                }
                paraLines.append(l)
                i += 1
            }
            if !paraLines.isEmpty {
                blocks.append(.paragraph(paraLines.joined(separator: " ")))
            }
        }

        return blocks
    }

    private static func isHorizontalRule(_ s: String) -> Bool {
        let dashes = s.filter { $0 == "-" }.count
        if dashes >= 3 && dashes == s.count { return true }
        let stars = s.filter { $0 == "*" }.count
        if stars >= 3 && stars == s.count { return true }
        let underscores = s.filter { $0 == "_" }.count
        if underscores >= 3 && underscores == s.count { return true }
        return false
    }

    private static func isUnorderedListItem(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func stripUnorderedPrefix(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("* ") { return String(trimmed.dropFirst(2)) }
        if trimmed.hasPrefix("+ ") { return String(trimmed.dropFirst(2)) }
        return trimmed
    }

    private static func isOrderedListItem(_ s: String) -> Bool {
        guard let dotIndex = s.firstIndex(of: ".") else { return false }
        let prefix = s[s.startIndex..<dotIndex]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return false }
        let afterDot = s.index(after: dotIndex)
        return afterDot < s.endIndex && s[afterDot] == " "
    }

    private static func stripOrderedPrefix(_ line: String) -> (Int, String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return (1, trimmed) }
        let prefix = String(trimmed[trimmed.startIndex..<dotIndex])
        let num = Int(prefix) ?? 1
        let afterDot = trimmed.index(after: dotIndex)
        let contentStart = trimmed[afterDot...].firstIndex(where: { !$0.isWhitespace })
            ?? trimmed.endIndex
        return (num, String(trimmed[contentStart...]))
    }

    private static func isTableRow(_ s: String) -> Bool {
        s.hasPrefix("|") && s.hasSuffix("|")
    }

    private static func isTableDelimiter(_ s: String) -> Bool {
        guard isTableRow(s) else { return false }
        let cells = parseTableRowCells(s)
        return cells.allSatisfy { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
    }

    private static func parseTableRowCells(_ line: String) -> [String] {
        var stripped = line
        if stripped.hasPrefix("|") { stripped = String(stripped.dropFirst()) }
        if stripped.hasSuffix("|") { stripped = String(stripped.dropLast()) }
        return stripped.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Inline Markdown Text (uses Apple's built-in parser)

/// Renders inline markdown using AttributedString(markdown:).
/// Apple's parser handles: **bold**, *italic*, `code`, [links](url),
/// ~~strikethrough~~ (via extensions), headers, lists.
/// Falls back to plain text if parsing fails.
struct MarkdownText: View {
    let text: String

    init(text: String) {
        self.text = text
    }

    var body: some View {
        if let attributed = parseMarkdown(text) {
            Text(attributed)
                .textSelection(.enabled)
        } else {
            Text(text)
                .textSelection(.enabled)
        }
    }

    private func parseMarkdown(_ input: String) -> AttributedString? {
        // Apple's AttributedString supports CommonMark subset:
        // bold, italic, inline code, links, strikethrough (with interpretationOptions)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible

        return try? AttributedString(markdown: input, options: options)
    }
}

// MARK: - Block Views

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with language label + copy button
            HStack {
                if !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    #else
                    UIPasteboard.general.string = code
                    #endif
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isCopied = false
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.caption2)
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            #if os(macOS)
            .background(Color(nsColor: .windowBackgroundColor))
            #else
            .background(Color(uiColor: .systemGroupedBackground))
            #endif

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        #if os(macOS)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        #else
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.5))
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                #if os(macOS)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                #else
                .stroke(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5)
                #endif
        )
    }
}

struct HeadingView: View {
    let level: Int
    let content: String

    var body: some View {
        MarkdownText(text: content)
            .font(font)
            .padding(.top, level >= 3 ? 4 : 8)
    }

    private var font: Font {
        switch level {
        case 1: return Font.title.bold()
        case 2: return Font.title2.bold()
        case 3: return Font.title3.bold()
        default: return Font.headline
        }
    }
}

struct ListItemView: View {
    let index: Int
    let content: String
    let isOrdered: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(isOrdered ? "\(index)." : "•")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: isOrdered ? 24 : 12, alignment: .trailing)
            MarkdownText(text: content)
        }
    }
}

struct BlockQuoteView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.4))
                .frame(width: 3)
                .padding(.trailing, 8)
            MarkdownText(text: content)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }
}

// MARK: - Table View

struct TableView: View {
    let headers: [String]
    let rows: [[String]]
    @State private var isExpanded = false

    var body: some View {
        let content = tableContent

        if isExpanded {
            content
        } else {
            content
                .frame(maxHeight: 220)
                .clipped()
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: 200)
                        LinearGradient(
                            colors: [Theme.surface, Theme.surface.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 20)
                    }
                )
        }
    }

    private var tableContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        MarkdownText(text: header)
                            .font(.caption.bold())
                            .foregroundStyle(Theme.secondary)
                            .frame(minWidth: 60, alignment: .center)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                    }
                }
                .background(Theme.surface)

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            MarkdownText(text: cell)
                                .font(.caption)
                                .foregroundStyle(Theme.primary)
                                .frame(minWidth: 60, alignment: .center)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        }
                    }
                    .background(rowIndex % 2 == 0 ? Theme.background : Theme.surface.opacity(0.4))
                }

                // Expand / collapse button
                if rows.count > 4 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Show less" : "Show all \(rows.count) rows")
                                .font(.caption2)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .background(Theme.surface)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Openable Block Chip (Mermaid / HTML)

struct OpenableBlockChip: View {
    let label: String
    let language: String
    let content: String
    @State private var isOpen = false

    var body: some View {
        Button {
            isOpen = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: language == "mermaid" ? "diagram" : "globe")
                    .font(.caption2)
                Text(label)
                    .font(.caption2)
                    .fontWeight(.medium)
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2)
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isOpen) {
            OpenableBlockSheet(language: language, content: content)
        }
    }
}

// MARK: - Openable Block Sheet

struct OpenableBlockSheet: View {
    let language: String
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text(language == "mermaid" ? "Diagram" : "Page")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primary)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surface)

            Divider()

            // Content
            if language == "mermaid" {
                MermaidDiagramView(mermaidCode: content)
            } else {
                InlineHTMLView(html: content)
            }
        }
        .frame(minWidth: 600, minHeight: 500)
        .background(Theme.background)
    }
}

// MARK: - Inline HTML View

struct InlineHTMLView: View {
    let html: String

    var body: some View {
        #if os(macOS)
        InlineHTMLNSView(html: html)
        #else
        InlineHTMLUIView(html: html)
        #endif
    }
}

#if os(macOS)
struct InlineHTMLNSView: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#else
struct InlineHTMLUIView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#endif
