import SwiftUI
import WebKit
import Highlightr
import os

/// Parses and renders markdown content in a SwiftUI view.
/// Uses Apple's built-in AttributedString(markdown:) for inline formatting
/// and custom block parsing for code blocks, headings, lists, etc.
struct MarkdownContentView: View, Equatable {
    let text: String
    let isStreaming: Bool

    init(text: String, isStreaming: Bool = false) {
        self.text = text
        self.isStreaming = isStreaming
    }

    nonisolated static func == (lhs: MarkdownContentView, rhs: MarkdownContentView) -> Bool {
        lhs.text == rhs.text && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .codeBlock(let language, let code):
                    if MarkdownParser.isChartLanguage(language) {
                        NativeChartView(json: code, isStreaming: isStreaming)
                    } else if MarkdownParser.isDiagramLanguage(language) {
                        DiagramPreviewBlock(mermaidCode: code, language: language, isStreaming: isStreaming)
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
                    if let githubLink = GitHubLinkCard.extractStandalone(from: content) {
                        GitHubLinkCard(link: githubLink)
                    } else {
                        MarkdownText(text: content)
                            .foregroundStyle(Theme.primary)
                            .lineSpacing(3)
                    }
                case .mathBlock(let tex):
                    MathBlockView(tex: tex)
                }
            }
        }
    }

    private var blocks: [MarkdownBlock] {
        MarkdownParseCache.shared.blocks(for: text)
    }
}

final class MarkdownParseCache: @unchecked Sendable {
    static let shared = MarkdownParseCache()

    private let lock = NSLock()
    private var cachedInput: String = ""
    private var cachedBlocks: [MarkdownBlock] = []
    private var completedCache: [Int: [MarkdownBlock]] = [:]
    private var completedOrder: [Int] = []
    private let completedLimit = 32
    #if DEBUG
    private(set) var parseCount = 0
    #endif

    func blocks(for input: String) -> [MarkdownBlock] {
        lock.lock()
        if input == cachedInput {
            let blocks = cachedBlocks
            lock.unlock()
            return blocks
        }
        let key = input.hashValue
        if let blocks = completedCache[key], input.count > 2_400 {
            cachedInput = input
            cachedBlocks = blocks
            lock.unlock()
            return blocks
        }
        lock.unlock()

        let parsed = MarkdownParser.parse(input)

        lock.lock()
        #if DEBUG
        parseCount += 1
        #endif
        cachedInput = input
        cachedBlocks = parsed
        if input.count > 2_400 {
            completedCache[key] = parsed
            completedOrder.removeAll { $0 == key }
            completedOrder.append(key)
            while completedOrder.count > completedLimit {
                let evicted = completedOrder.removeFirst()
                completedCache.removeValue(forKey: evicted)
            }
        }
        lock.unlock()
        return parsed
    }

    #if DEBUG
    func resetForTesting() {
        lock.lock()
        cachedInput = ""
        cachedBlocks = []
        completedCache = [:]
        completedOrder = []
        parseCount = 0
        lock.unlock()
    }
    #endif
}

// MARK: - Block Types

enum MarkdownBlock: Equatable, Identifiable {
    case paragraph(String)
    case heading(level: Int, content: String)
    case codeBlock(language: String, code: String)
    case listItem(index: Int, content: String, isOrdered: Bool)
    case blockquote(content: String)
    case horizontalRule
    case table(headers: [String], rows: [[String]])
    case mathBlock(String)

    var id: String {
        switch self {
        case .paragraph(let content): return "p-\(content.prefix(64))"
        case .heading(let level, let content): return "h\(level)-\(content.prefix(64))"
        case .codeBlock(let language, let code): return "code-\(language)-\(code.prefix(64))"
        case .listItem(let index, let content, let isOrdered): return "li\(isOrdered ? "o" : "u")-\(index)-\(content.prefix(64))"
        case .blockquote(let content): return "bq-\(content.prefix(64))"
        case .horizontalRule: return "hr"
        case .table(let headers, _): return "table-\(headers.joined(separator: "|"))"
        case .mathBlock(let tex): return "math-\(tex.prefix(64))"
        }
    }
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

            // Math block
            if trimmed.hasPrefix("$$") {
                var mathLines: [String] = []
                if trimmed.count > 2 {
                    // Single-line $$...$$
                    let content = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                    let endIdx = content.index(content.endIndex, offsetBy: -2, limitedBy: content.startIndex)
                    let cleaned = (endIdx != nil && content.suffix(2) == "$$") ? String(content.prefix(content.count - 2)) : content
                    if !cleaned.isEmpty {
                        blocks.append(.mathBlock(cleaned.trimmingCharacters(in: .whitespaces)))
                    }
                    i += 1
                    continue
                }
                // Multi-line $$
                i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("$$") {
                    mathLines.append(lines[i])
                    i += 1
                }
                if i < lines.count { i += 1 }
                let tex = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
                if !tex.isEmpty {
                    blocks.append(.mathBlock(tex))
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

    static let diagramLanguages: Set<String> = [
        "mermaid", "flowchart", "sequence", "sequencediagram", "statediagram",
        "classdiagram", "erdiagram", "er", "gantt", "pie", "mindmap",
        "timeline", "gitgraph", "sankey", "block", "quadrant", "radar",
        "treemap", "xychart", "journey", "kanban", "architecture",
    ]

    static func isDiagramLanguage(_ language: String) -> Bool {
        diagramLanguages.contains(language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func isChartLanguage(_ language: String) -> Bool {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "chart"
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
/// Caches the parsed result so repeated body evaluations (e.g. during
/// streaming token-by-token updates from the parent) do not re-parse
/// the same growing text on every frame.
struct MarkdownText: View {
    let text: String
    var baseColor: Color?
    var baseFont: Font?

    /// The pre-computed attributed string. Parsing happens once in init
    /// so body() is O(1) — critical during streaming where the parent
    /// may re-evaluate frequently but the text changes token-by-token.
    private let rendered: AttributedString

    init(text: String, baseColor: Color? = nil, baseFont: Font? = nil) {
        self.text = text
        self.baseColor = baseColor
        self.baseFont = baseFont
        self.rendered = Self.render(text, baseColor: baseColor, baseFont: baseFont)
    }

    var body: some View {
        SwiftUI.Text(rendered)
            .textSelection(.enabled)
    }

    private static func render(_ input: String, baseColor: Color?, baseFont: Font?) -> AttributedString {
        let textColor: Color = baseColor ?? Theme.primary
        let font: Font = baseFont ?? .system(size: 14)

        let normalized = Self.normalizeInlineCode(input)

        if var parsed = try? AttributedString(markdown: normalized, options: inlineOptions) {
            stripSystemColors(&parsed, to: textColor)
            applyBaseFont(&parsed, font: font)
            applyInlineCodeStyling(&parsed)
            return parsed
        }

        // Fallback: use regex to style inline code when native parser fails
        if var fallback = try? AttributedString(markdown: normalized, options: .init()) {
            stripSystemColors(&fallback, to: textColor)
            applyBaseFont(&fallback, font: font)
            applyInlineCodeStyling(&fallback)
            return fallback
        }

        var plain = AttributedString(normalized)
        #if os(macOS)
        plain.foregroundColor = NSColor(textColor)
        #else
        plain.foregroundColor = UIColor(textColor)
        #endif
        applyBaseFont(&plain, font: font)
        return plain
    }

    /// Escape unpaired backticks so the AttributedString parser doesn't bail out.
    private static func normalizeInlineCode(_ input: String) -> String {
        var result = input

        // Fix unpaired backticks: count them, if odd, escape the last one
        var backtickCount = 0
        for char in result where char == "`" {
            backtickCount += 1
        }
        if backtickCount % 2 != 0 {
            if let lastIdx = result.lastIndex(of: "`") {
                result = result.replacingOccurrences(of: "`", with: "\\`", range: lastIdx..<result.index(after: lastIdx))
            }
        }
        return result
    }

    private static func applyInlineCodeStyling(_ attr: inout AttributedString) {
        #if os(macOS)
        let codeBg = NSColor(Theme.surfaceHover)
        let codeFg = NSColor(Theme.accent)
        #else
        let codeBg = UIColor(Theme.surfaceHover)
        let codeFg = UIColor(Theme.accent)
        #endif

        let codeFontBase: Font = .system(size: 12, design: .monospaced)
        for i in attr.runs.indices {
            let run = attr.runs[i]
            guard let intent = run.inlinePresentationIntent,
                  intent.contains(.code) else { continue }

            // Skip short single-word spans — they're usually prose emphasis, not code
            let content = String(attr[run.range].characters)
            guard content.contains(where: { $0.isWhitespace }) || content.count >= 10 else { continue }

            let inheritedWeight: Font.Weight = intent.contains(.stronglyEmphasized) ? .bold : .regular

            attr[run.range].font = codeFontBase.weight(inheritedWeight)
            attr[run.range].backgroundColor = codeBg
            attr[run.range].foregroundColor = codeFg
        }
    }

    private static func applyBaseFont(_ attr: inout AttributedString, font: Font) {
        for i in attr.runs.indices where attr.runs[i].font == nil {
            attr[attr.runs[i].range].font = font
        }
    }
    private static func stripSystemColors(_ attr: inout AttributedString, to color: Color) {
        for i in attr.runs.indices {
            let run = attr.runs[i]
            if run.foregroundColor != nil, run.backgroundColor == nil {
                #if os(macOS)
                attr[run.range].foregroundColor = NSColor(color)
                #else
                attr[run.range].foregroundColor = UIColor(color)
                #endif
            }
        }
    }

    private static var inlineOptions: AttributedString.MarkdownParsingOptions {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return options
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
                Text(highlightedCode)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
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

    private var highlightedCode: AttributedString {
        CodeHighlighter.highlight(code, language: language)
    }
}

// MARK: - Diagram Preview Block

struct DiagramPreviewBlock: View {
    let mermaidCode: String
    let language: String
    let isStreaming: Bool
    @State private var isOpen = false
    @State private var isExploring = false

    private var typeLabel: String {
        MermaidDiagramView.diagramTypeLabel(for: mermaidCode)
    }

    private var canExplore: Bool {
        !isStreaming && MermaidGraphParser.canExplore(mermaidCode)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Preview adapts to the diagram's aspect ratio (ZoomableDiagram
            // sizes itself to the image); cap the inline height and rely on
            // tap-to-open for the full view.
            MermaidDiagramView(mermaidCode: mermaidCode, isStreaming: isStreaming)
                .frame(minHeight: 120, maxHeight: 600)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture {
                    isOpen = true
                }

            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                Text("\(typeLabel) — open")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if canExplore {
                    Button {
                        isExploring = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .font(.system(size: 9, weight: .bold))
                            Text("Explore")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderless)
                }
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.accent.opacity(0.06))
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        #if os(iOS)
        .fullScreenCover(isPresented: $isOpen) {
            OpenableBlockSheet(language: language, content: mermaidCode)
        }
        .fullScreenCover(isPresented: $isExploring) {
            if let explorer = DiagramExplorerView(mermaidSource: mermaidCode, title: "\(typeLabel) — Explorer") {
                explorer
            }
        }
        #else
        .sheet(isPresented: $isOpen) {
            OpenableBlockSheet(language: language, content: mermaidCode)
                .frame(
                    width: min((NSScreen.main?.visibleFrame.width ?? 1200) * 0.85, 1400),
                    height: min((NSScreen.main?.visibleFrame.height ?? 800) * 0.85, 900)
                )
        }
        .sheet(isPresented: $isExploring) {
            if let explorer = DiagramExplorerView(mermaidSource: mermaidCode, title: "\(typeLabel) — Explorer") {
                explorer
                    .frame(
                        width: min((NSScreen.main?.visibleFrame.width ?? 1200) * 0.85, 1400),
                        height: min((NSScreen.main?.visibleFrame.height ?? 800) * 0.85, 900)
                    )
            }
        }
        #endif
    }
}

// MARK: - Code Highlighter (Highlightr)

private enum CodeHighlighter {
    nonisolated(unsafe) private static let highlightr: Highlightr? = {
        let h = Highlightr()
        h?.setTheme(to: "atom-one-dark")
        return h
    }()

    static func highlight(_ code: String, language: String) -> AttributedString {
        guard let highlightr,
              let attributed = highlightr.highlight(code, as: mapLanguage(language))
        else {
            var fallback = AttributedString(code)
            fallback.font = .system(size: 12, weight: .regular, design: .monospaced)
            return fallback
        }
        var result = AttributedString(attributed)
        result.font = .system(size: 12, weight: .regular, design: .monospaced)
        return result
    }

    private static func mapLanguage(_ lang: String) -> String {
        switch lang.lowercased() {
        case "py": return "python"
        case "js": return "javascript"
        case "ts": return "typescript"
        case "sh", "zsh", "shell": return "bash"
        case "yml": return "yaml"
        default: return lang.lowercased()
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
    /// Column index the rows are sorted by; nil = source order.
    @State private var sortColumn: Int?
    @State private var sortAscending = true
    @State private var copied = false

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

    // MARK: Sorting

    /// Rows in display order. Numeric columns sort numerically (an LLM table
    /// column is numeric when every non-empty cell parses); otherwise
    /// case-insensitive text. Empty cells always sink to the bottom.
    private var displayRows: [[String]] {
        guard let col = sortColumn else { return normalizedRows }
        let numeric = columnIsNumeric(col)
        return normalizedRows.sorted { a, b in
            let x = col < a.count ? a[col] : ""
            let y = col < b.count ? b[col] : ""
            if x.isEmpty != y.isEmpty { return y.isEmpty }
            let ordered: Bool
            if numeric, let nx = Self.numericValue(x), let ny = Self.numericValue(y) {
                ordered = nx < ny
            } else {
                ordered = x.localizedCaseInsensitiveCompare(y) == .orderedAscending
            }
            return sortAscending ? ordered : !ordered
        }
    }

    private func columnIsNumeric(_ col: Int) -> Bool {
        let cells = normalizedRows.compactMap { col < $0.count ? $0[col] : nil }
            .filter { !$0.isEmpty }
        return !cells.isEmpty && cells.allSatisfy { Self.numericValue($0) != nil }
    }

    /// Parse "1,234", "45%", "$12.50" — the units LLM tables actually carry.
    private static func numericValue(_ s: String) -> Double? {
        let cleaned = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "$€£%"))
        return Double(cleaned)
    }

    private func toggleSort(column: Int) {
        if sortColumn == column {
            if sortAscending {
                sortAscending = false
            } else {
                sortColumn = nil       // third click restores source order
                sortAscending = true
            }
        } else {
            sortColumn = column
            sortAscending = true
        }
    }

    // MARK: CSV export

    private var csv: String {
        func escape(_ cell: String) -> String {
            if cell.contains(",") || cell.contains("\"") || cell.contains("\n") {
                return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return cell
        }
        let lines = [headers.map(escape).joined(separator: ",")]
            + displayRows.map { $0.map(escape).joined(separator: ",") }
        return lines.joined(separator: "\n")
    }

    private func copyCSV() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
        #else
        UIPasteboard.general.string = csv
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private var tableContent: some View {
        let widths = columnWidths
        let tableWidth = widths.reduce(0, +)

        return ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row — click a column to sort (asc → desc → source order)
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        Button {
                            toggleSort(column: index)
                        } label: {
                            HStack(spacing: 3) {
                                tableCell(
                                    text: header,
                                    width: columnWidth(at: index, from: widths),
                                    isHeader: true
                                )
                                if sortColumn == index {
                                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.trailing, 4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Sort by \(header)")
                    }
                    copyButton
                }
                .background(Theme.accent.opacity(0.08))

                // Data rows
                ForEach(Array(displayRows.enumerated()), id: \.offset) { rowIndex, row in
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
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var copyButton: some View {
        Button(action: copyCSV) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copied ? .green : Theme.secondary)
                .padding(.horizontal, 8)
        }
        .buttonStyle(.plain)
        .help("Copy table as CSV")
        .accessibilityLabel("Copy table as CSV")
    }

    @ViewBuilder
    private func tableCell(text: String, width: CGFloat, isHeader: Bool) -> some View {
        MarkdownText(
            text: text,
            baseColor: isHeader ? Theme.accent : nil,
            baseFont: isHeader ? .system(size: 11, weight: .bold, design: .monospaced) : nil
        )
        .textSelection(.enabled)
        .lineLimit(nil)
        .multilineTextAlignment(isHeader ? .center : .leading)
        .frame(minWidth: width, alignment: isHeader ? .center : .leading)
        .padding(.horizontal, 10)
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
            let longest = values.map { visualRenderedLength($0) }.max() ?? 0
            let headerLength = visualRenderedLength(headers[index])
            let characterWidth: CGFloat = 8
            let horizontalPadding: CGFloat = 24
            let computed = CGFloat(max(longest, headerLength)) * characterWidth + horizontalPadding
            return max(computed, Self.minimumColumnWidth)
        }
    }

    private func visualRenderedLength(_ text: String) -> Int {
        let stripped = text
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "~~", with: "")
        return stripped.reduce(0) { total, scalar in
            total + (scalar.isASCII ? 1 : 2)
        }
    }

    private static let minimumColumnWidth: CGFloat = 96
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
            #if os(macOS)
            HTMLPreviewPresenter.shared.showBlock(language: language, content: content)
            #else
            isOpen = true
            #endif
        } label: {
            HStack(spacing: 5) {
                Image(systemName: MarkdownParser.isDiagramLanguage(language) ? "arrow.up.left.and.arrow.down.right" : "safari")
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
        // macOS routes through HTMLPreviewPresenter (full-window SwiftUI overlay).
        .fullScreenCover(isPresented: $isOpen) {
            OpenableBlockSheet(language: language, content: content)
        }
        #endif
    }
}

#if os(macOS)
/// Shared presenter for the full-window HTML/file preview overlay.
///
/// Injecting an AppKit subview into SwiftUI's window contentView "succeeded"
/// (presentOverlay ran, host found) but rendered nothing — SwiftUI owns that
/// hierarchy and the subview sat behind/ignored. So drive the overlay through
/// SwiftUI instead: this observable holds the content, and ContentView renders
/// it as a top-level .overlay (the same pattern Wiki/Feed full-window overlays
/// use, which work).
@MainActor
final class HTMLPreviewPresenter: ObservableObject {
    static let shared = HTMLPreviewPresenter()
    enum Payload: Equatable {
        case block(language: String, content: String)
        case attachment(FileAttachment)
        static func == (a: Payload, b: Payload) -> Bool {
            switch (a, b) {
            case let (.block(l1, c1), .block(l2, c2)): return l1 == l2 && c1 == c2
            case let (.attachment(x), .attachment(y)): return x.id == y.id
            default: return false
            }
        }
    }
    @Published var payload: Payload?

    func showBlock(language: String, content: String) { payload = .block(language: language, content: content) }
    func showAttachment(_ attachment: FileAttachment) { payload = .attachment(attachment) }
    func close() { payload = nil }
}

/// The full-window overlay view, mounted once at the app root by ContentView.
struct HTMLPreviewOverlay: View {
    @ObservedObject private var presenter = HTMLPreviewPresenter.shared

    var body: some View {
        if let payload = presenter.payload {
            Group {
                switch payload {
                case let .block(language, content):
                    OpenableBlockSheet(language: language, content: content, onClose: { presenter.close() })
                case let .attachment(attachment):
                    FilePreviewView(attachment: attachment, onClose: { presenter.close() })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .transition(.opacity)
        }
    }
}

#endif

// MARK: - Openable Block Sheet

struct OpenableBlockSheet: View {
    let language: String
    let content: String
    /// When hosted in a standalone NSWindow (macOS), @Environment(\.dismiss)
    /// doesn't apply — the host passes a close action instead.
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    private var isDiagram: Bool {
        MarkdownParser.isDiagramLanguage(language)
    }

    private var title: String {
        isDiagram ? MermaidDiagramView.diagramTypeLabel(for: content) : "Page"
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Title bar
                HStack(spacing: 10) {
                    Image(systemName: isDiagram ? "chart.bar.doc.horizontal" : "globe")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)

                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.primary)

                    Spacer()

                    Button {
                        if let onClose { onClose() } else { dismiss() }
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

                // Content — diagram or HTML. Fill all available sheet space so
                // an opened HTML page uses the whole window, not a small box.
                Group {
                    if isDiagram {
                        MermaidDiagramView(mermaidCode: content, isStreaming: false)
                    } else {
                        InlineHTMLView(html: content)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        guard context.coordinator.lastLoadedHTML != html else { return }
        context.coordinator.lastLoadedHTML = html
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
        // Match macOS: embedded media plays inline instead of hijacking the
        // screen with the system fullscreen player, and element-fullscreen
        // requests (charts, embeds) are honored instead of silently ignored.
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.isElementFullscreenEnabled = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastLoadedHTML != html else { return }
        context.coordinator.lastLoadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#endif

final class HTMLNavigationDelegate: NSObject, WKNavigationDelegate {
    var lastLoadedHTML: String?
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

// MARK: - Math Block

struct MathBlockView: View {
    let tex: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "function")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Math")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tex, forType: .string)
                    #else
                    UIPasteboard.general.string = tex
                    #endif
                    isCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        isCopied = false
                    }
                } label: {
                    Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            Text(tex)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
