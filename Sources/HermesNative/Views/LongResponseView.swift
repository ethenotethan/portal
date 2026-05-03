import SwiftUI

/// Presentation wrapper for long assistant responses.
///
/// Keeps the normal markdown renderer for short answers, but adds a compact
/// navigation summary and section-level folding for long generated responses
/// so large review/explanation outputs are easier to scan.
struct LongResponseView: View {
    let text: String
    let isStreaming: Bool

    @State private var collapsedHeadings: Set<Int> = []
    @State private var showOverview = true
    @State private var compactMode = false

    private var document: LongResponseDocument {
        LongResponseDocument(markdown: text)
    }

    private var shouldEnhance: Bool {
        !isStreaming && document.shouldEnhance
    }

    var body: some View {
        if shouldEnhance {
            enhancedBody
        } else {
            MarkdownContentView(text: text, isStreaming: isStreaming)
        }
    }

    private var enhancedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            LongResponseOverview(
                document: document,
                showOverview: $showOverview,
                compactMode: $compactMode,
                expandAll: expandAll,
                collapseAll: collapseAll
            )

            VStack(alignment: .leading, spacing: compactMode ? 8 : 12) {
                ForEach(document.sections) { section in
                    if section.isIntro {
                        if !compactMode {
                            MarkdownContentView(text: section.markdown)
                        }
                    } else {
                        LongResponseSectionView(
                            section: section,
                            isCollapsed: collapsedHeadings.contains(section.id),
                            compactMode: compactMode,
                            toggle: { toggle(section) }
                        )
                    }
                }
            }
        }
    }

    private func toggle(_ section: LongResponseSection) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedHeadings.contains(section.id) {
                collapsedHeadings.remove(section.id)
            } else {
                collapsedHeadings.insert(section.id)
            }
        }
    }

    private func collapseAll() {
        withAnimation(.easeInOut(duration: 0.18)) {
            collapsedHeadings = Set(document.sections.filter { !$0.isIntro }.map(\.id))
        }
    }

    private func expandAll() {
        withAnimation(.easeInOut(duration: 0.18)) {
            collapsedHeadings.removeAll()
        }
    }
}

// MARK: - Overview

private struct LongResponseOverview: View {
    let document: LongResponseDocument
    @Binding var showOverview: Bool
    @Binding var compactMode: Bool
    let expandAll: () -> Void
    let collapseAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)

                Text("Long response")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)

                Text(document.statsLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondary)

                Spacer(minLength: 8)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showOverview.toggle() }
                } label: {
                    Label(showOverview ? "Hide map" : "Show map", systemImage: showOverview ? "chevron.up" : "chevron.down")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(LongResponseTinyButtonStyle(tint: Theme.secondary))
            }

            if showOverview {
                if !document.headings.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(document.headings.prefix(8)) { heading in
                            HStack(spacing: 7) {
                                Text(String(repeating: "  ", count: max(0, heading.level - 2)))
                                    .font(.system(size: 1))
                                Circle()
                                    .fill(heading.level <= 2 ? Theme.accent : Theme.border)
                                    .frame(width: 5, height: 5)
                                Text(heading.title)
                                    .font(.system(size: 11, weight: heading.level <= 2 ? .semibold : .regular))
                                    .foregroundStyle(heading.level <= 2 ? Theme.primary : Theme.secondary)
                                    .lineLimit(1)
                            }
                        }

                        if document.headings.count > 8 {
                            Text("+ \(document.headings.count - 8) more sections")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                                .padding(.leading, 12)
                        }
                    }
                } else if let skim = document.skimText {
                    Text(skim)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("Expand all", action: expandAll)
                        .buttonStyle(LongResponseTinyButtonStyle(tint: Theme.accent))
                    Button("Collapse all", action: collapseAll)
                        .buttonStyle(LongResponseTinyButtonStyle(tint: Theme.secondary))
                    Button(compactMode ? "Detailed" : "Compact") {
                        withAnimation(.easeInOut(duration: 0.18)) { compactMode.toggle() }
                    }
                    .buttonStyle(LongResponseTinyButtonStyle(tint: Theme.secondary))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}

private struct LongResponseSectionView: View {
    let section: LongResponseSection
    let isCollapsed: Bool
    let compactMode: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: compactMode ? 6 : 10) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 12)

                    Text(section.title)
                        .font(.system(size: titleSize, weight: titleWeight))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Text(section.summaryLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isCollapsed ? "Expand" : "Collapse") section \(section.title)")

            if !isCollapsed {
                if compactMode, let preview = section.previewMarkdown {
                    MarkdownContentView(text: preview)
                } else if !section.bodyMarkdown.isEmpty {
                    MarkdownContentView(text: section.bodyMarkdown)
                }
            }
        }
        .padding(.leading, CGFloat(max(0, section.level - 2)) * 10)
        .padding(.vertical, compactMode ? 6 : 8)
        .padding(.horizontal, compactMode ? 8 : 10)
        .background(section.level <= 2 ? Theme.background.opacity(0.45) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(section.level <= 2 ? Theme.accent.opacity(0.6) : Theme.border.opacity(0.8))
                .frame(width: section.level <= 2 ? 2 : 1)
        }
    }

    private var titleSize: CGFloat {
        switch section.level {
        case 1: 17
        case 2: 15
        case 3: 13
        default: 12
        }
    }

    private var titleWeight: Font.Weight {
        section.level <= 2 ? .bold : .semibold
    }
}

private struct LongResponseTinyButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(configuration.isPressed ? tint.opacity(0.18) : tint.opacity(0.08))
            )
            .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 0.5))
    }
}

// MARK: - Document Model

private struct LongResponseDocument {
    let markdown: String
    let sections: [LongResponseSection]
    let headings: [LongResponseHeading]
    let wordCount: Int

    init(markdown: String) {
        self.markdown = markdown
        let parsed = Self.parseSections(markdown)
        self.sections = parsed.sections
        self.headings = parsed.headings
        self.wordCount = Self.countWords(markdown)
    }

    var shouldEnhance: Bool {
        markdown.count > 2400 || headings.count >= 3 || wordCount > 380
    }

    var statsLabel: String {
        var parts: [String] = []
        if headings.count > 0 { parts.append("\(headings.count) sections") }
        parts.append("~\(max(1, wordCount / 100) * 100) words")
        return parts.joined(separator: " · ")
    }

    var skimText: String? {
        let stripped = markdown
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: " ")
            .replacingOccurrences(of: "#", with: "")
            .split(separator: " ")
            .joined(separator: " ")
        guard !stripped.isEmpty else { return nil }
        return String(stripped.prefix(240))
    }

    private static func parseSections(_ markdown: String) -> (sections: [LongResponseSection], headings: [LongResponseHeading]) {
        let lines = markdown.components(separatedBy: "\n")
        var sections: [LongResponseSection] = []
        var headings: [LongResponseHeading] = []
        var currentHeading: (level: Int, title: String)?
        var buffer: [String] = []
        var id = 0
        var inCodeBlock = false

        func flush() {
            let body = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading = currentHeading {
                sections.append(LongResponseSection(
                    id: id,
                    level: heading.level,
                    title: heading.title,
                    bodyMarkdown: body,
                    isIntro: false
                ))
                id += 1
            } else if !body.isEmpty {
                sections.append(LongResponseSection(
                    id: id,
                    level: 0,
                    title: "Overview",
                    bodyMarkdown: body,
                    isIntro: true
                ))
                id += 1
            }
            buffer.removeAll()
        }

        for line in lines {
            if line.hasPrefix("```") {
                inCodeBlock.toggle()
                buffer.append(line)
                continue
            }

            if !inCodeBlock, let heading = parseHeading(line) {
                flush()
                currentHeading = heading
                headings.append(LongResponseHeading(id: id, level: heading.level, title: heading.title))
            } else {
                buffer.append(line)
            }
        }
        flush()

        if sections.isEmpty {
            sections.append(LongResponseSection(id: 0, level: 0, title: "Response", bodyMarkdown: markdown, isIntro: true))
        }
        return (sections, headings)
    }

    private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...4).contains(hashes) else { return nil }
        let rest = String(line.dropFirst(hashes))
        guard rest.first?.isWhitespace == true else { return nil }
        let title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return (hashes, title)
    }

    private static func countWords(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct LongResponseHeading: Identifiable {
    let id: Int
    let level: Int
    let title: String
}

private struct LongResponseSection: Identifiable {
    let id: Int
    let level: Int
    let title: String
    let bodyMarkdown: String
    let isIntro: Bool

    var markdown: String {
        isIntro ? bodyMarkdown : "\(String(repeating: "#", count: max(1, level))) \(title)\n\n\(bodyMarkdown)"
    }

    var summaryLabel: String {
        let words = bodyMarkdown.split { $0.isWhitespace || $0.isNewline }.count
        if words == 0 { return "empty" }
        return "~\(max(1, words / 50) * 50)w"
    }

    var previewMarkdown: String? {
        let blocks = bodyMarkdown.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = blocks.first else { return nil }
        if first.count <= 420 { return first }
        return String(first.prefix(420)) + "…"
    }
}
