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
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .codeBlock(let language, let code):
                    if language == "mermaid" {
                        MermaidDiagramView(mermaidCode: code)
                            .frame(minHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Theme.border, lineWidth: 0.5)
                            )
                        OpenableBlockChip(label: "Open Diagram", language: "mermaid", content: code)
                    } else if MarkdownParser.isHTMLLanguage(language) {
                        HTMLBlockView(html: code)
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
                    HStack {
                        Rectangle()
                            .fill(Theme.border)
                            .frame(height: 0.5)
                    }
                    .padding(.vertical, 4)
                case .table(let headers, let rows):
                    TableView(headers: headers, rows: rows)
                case .paragraph(let content):
                    MarkdownText(text: content)
                        .foregroundStyle(Theme.primary)
                        .lineSpacing(3)
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

    static func isHTMLLanguage(_ language: String) -> Bool {
        let normalized = language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "html" || normalized == "htm"
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

// MARK: - Inline Markdown Text

/// Renders inline markdown using AttributedString(markdown:).
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
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible

        return try? AttributedString(markdown: input, options: options)
    }
}

// MARK: - Block Views

// MARK: Code Block

struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                if !language.isEmpty {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(languageColor)
                            .frame(width: 6, height: 6)
                        Text(language)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                    }
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
                    HStack(spacing: 3) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isCopied ? Theme.success : Theme.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)

            // Code content
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private var languageColor: Color {
        switch language {
        case "swift": return .orange
        case "python", "py": return .yellow
        case "rust": return Theme.accent
        case "go": return .cyan
        case "bash", "sh", "zsh": return .green
        case "json": return Theme.warning
        case "yaml", "yml": return .pink
        case "html": return .red
        case "css": return .purple
        case "javascript", "js", "typescript", "ts": return .yellow
        default: return Theme.accent
        }
    }
}

// MARK: Heading

struct HeadingView: View {
    let level: Int
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if level == 1 {
                MarkdownText(text: content)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.primary)
                Rectangle()
                    .fill(Theme.accent.opacity(0.4))
                    .frame(height: 2)
                    .padding(.top, 4)
            } else {
                MarkdownText(text: content)
                    .font(font)
                    .foregroundStyle(Theme.primary)
            }
        }
        .padding(.top, level == 1 ? 12 : level == 2 ? 10 : 6)
    }

    private var font: Font {
        switch level {
        case 1: return Font.system(size: 22, weight: .bold)
        case 2: return Font.system(size: 18, weight: .bold)
        case 3: return Font.system(size: 15, weight: .semibold)
        case 4: return Font.system(size: 14, weight: .semibold)
        default: return Font.system(size: 13, weight: .semibold)
        }
    }
}

// MARK: List Item

struct ListItemView: View {
    let index: Int
    let content: String
    let isOrdered: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isOrdered {
                Text("\(index).")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, alignment: .trailing)
            } else {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 4)
                    .frame(width: 22, alignment: .center)
                    .padding(.top, 7)
            }
            MarkdownText(text: content)
                .font(.system(size: 14))
                .foregroundStyle(Theme.primary)
        }
    }
}

// MARK: Block Quote

struct BlockQuoteView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(
                    LinearGradient(
                        colors: [Theme.accent, Theme.accent.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 3)
                .padding(.trailing, 10)
            MarkdownText(text: content)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .italic()
        }
        .padding(.leading, 4)
        .padding(.vertical, 2)
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
                .frame(maxHeight: 240)
                .clipped()
                .mask(
                    VStack(spacing: 0) {
                        Rectangle().frame(height: 220)
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
        let widths = columnWidths
        let tableWidth = widths.reduce(0, +)

        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        tableCell(
                            text: header,
                            width: columnWidth(at: index, from: widths),
                            isHeader: true
                        )
                    }
                }
                .background(Theme.accent.opacity(0.08))

                // Data rows
                ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { index, cell in
                            tableCell(
                                text: cell,
                                width: columnWidth(at: index, from: widths),
                                isHeader: false
                            )
                        }
                    }
                    .background(rowIndex % 2 == 0 ? Theme.background : Theme.surface.opacity(0.3))
                }

                // Expand / collapse
                if rows.count > 5 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Collapse" : "\(rows.count) rows")
                                .font(.system(size: 11, weight: .semibold))
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(width: tableWidth, alignment: .center)
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .background(Theme.accent.opacity(0.05))
                }
            }
            .frame(width: tableWidth, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func tableCell(text: String, width: CGFloat, isHeader: Bool) -> some View {
        Text(text)
            .font(isHeader
                ? .system(size: 11, weight: .bold, design: .monospaced)
                : .system(size: 12, weight: .regular)
            )
            .foregroundStyle(isHeader ? Theme.accent : Theme.primary)
            .textSelection(.enabled)
            .lineLimit(nil)
            .multilineTextAlignment(.center)
            .frame(width: width, alignment: .center)
            .padding(.vertical, isHeader ? 8 : 7)
    }

    private var normalizedRows: [[String]] {
        rows.map { row in
            let missing = max(0, headers.count - row.count)
            return Array((row + Array(repeating: "", count: missing)).prefix(headers.count))
        }
    }

    private func columnWidth(at index: Int, from widths: [CGFloat]) -> CGFloat {
        index < widths.count ? widths[index] : Self.minimumColumnWidth
    }

    private var columnWidths: [CGFloat] {
        headers.indices.map { index in
            let values = [headers[index]] + normalizedRows.map { index < $0.count ? $0[index] : "" }
            let longest = values.map(visualLength).max() ?? 0
            let headerLength = visualLength(headers[index])
            let characterWidth: CGFloat = 8.5
            let horizontalPadding: CGFloat = 28
            let computed = CGFloat(max(longest, headerLength)) * characterWidth + horizontalPadding
            return min(max(computed, Self.minimumColumnWidth), Self.maximumColumnWidth)
        }
    }

    private func visualLength(_ text: String) -> Int {
        text.reduce(0) { total, scalar in
            total + (scalar.isASCII ? 1 : 2)
        }
    }

    private static let minimumColumnWidth: CGFloat = 96
    private static let maximumColumnWidth: CGFloat = 280
}

// MARK: - HTML Block

struct HTMLBlockView: View {
    let html: String

    private var previewText: String {
        let collapsed = html
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
        if collapsed.count <= 180 {
            return collapsed
        }
        return String(collapsed.prefix(180)) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red.opacity(0.14))
                    Image(systemName: "safari")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.red)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text("HTML Page")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text("Open in an isolated in-app web preview")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }

                Spacer()
            }

            Text(previewText)
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                OpenableBlockChip(label: "Open Page", language: "html", content: html)
                CopyHTMLButton(html: html)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}

struct CopyHTMLButton: View {
    let html: String
    @State private var isCopied = false

    var body: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(html, forType: .string)
            #else
            UIPasteboard.general.string = html
            #endif
            isCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                isCopied = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9, weight: .bold))
                Text(isCopied ? "Copied" : "Copy HTML")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(isCopied ? Theme.success : Theme.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.background))
            .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
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
                Image(systemName: language == "mermaid" ? "arrow.up.left.and.arrow.down.right" : "safari")
                    .font(.system(size: 9, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.accent.opacity(0.1))
            )
            .overlay(
                Capsule().stroke(Theme.accent.opacity(0.25), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        #if os(iOS)
        .fullScreenCover(isPresented: $isOpen) {
            OpenableBlockSheet(language: language, content: content)
        }
        #else
        .sheet(isPresented: $isOpen) {
            OpenableBlockSheet(language: language, content: content)
                .frame(
                    width: NSScreen.main?.visibleFrame.width ?? 1200,
                    height: NSScreen.main?.visibleFrame.height ?? 800
                )
        }
        #endif
    }
}

// MARK: - Openable Block Sheet

struct OpenableBlockSheet: View {
    let language: String
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Title bar
                HStack(spacing: 10) {
                    Image(systemName: language == "mermaid" ? "diagram" : "globe")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)

                    Text(language == "mermaid" ? "Diagram" : "Page")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.primary)

                    Spacer()

                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.tertiary)
                            .frame(width: 26, height: 26)
                            .background(Theme.surfaceHover, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Theme.surface)

                Divider().overlay(Theme.border)

                // Content — WKWebView handles its own scrolling
                Group {
                    if language == "mermaid" {
                        MermaidDiagramView(mermaidCode: content, isInteractive: true)
                    } else {
                        InlineHTMLView(html: content)
                    }
                }
                .padding(12)
            }
        }
        #if os(iOS)
        .navigationBarHidden(true)
        .statusBarHidden(false)
        #else
        .ignoresSafeArea()
        #endif
    }
}

// MARK: - Inline HTML View

struct InlineHTMLView: View {
    let html: String

    var body: some View {
        #if os(macOS)
        InlineHTMLNSView(html: html)
            .background(Theme.background)
        #else
        InlineHTMLUIView(html: html)
            .background(Theme.background)
        #endif
    }
}

#if os(macOS)
struct InlineHTMLNSView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> HTMLNavigationDelegate {
        HTMLNavigationDelegate()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.isElementFullscreenEnabled = true
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#else
struct InlineHTMLUIView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> HTMLNavigationDelegate {
        HTMLNavigationDelegate()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#endif

final class HTMLNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else {
            decisionHandler(.allow)
            return
        }

        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
        decisionHandler(.cancel)
    }
}
