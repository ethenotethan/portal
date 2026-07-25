import SwiftUI

/// Visual breakdown of the assembled system prompt showing all injected context sections,
/// token allocation, and content inspection.
///
/// Use as a sheet or navigation destination via:
/// ```swift
/// .sheet(isPresented: $showPromptBreakdown) {
///     PromptBreakdownView(breakdown: .mock, isLoading: false)
/// }
/// ```
struct PromptBreakdownView: View {
    let breakdown: PromptBreakdown
    let isLoading: Bool

    @State private var expandedSections: Set<String> = []
    @State private var searchText: String = ""
    @Environment(\.dismiss) private var dismiss

    // MARK: - Init

    init(breakdown: PromptBreakdown, isLoading: Bool = false) {
        self.breakdown = breakdown
        self.isLoading = isLoading
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            if isLoading {
                loadingBody
            } else {
                mainContent
            }
        }
        .onAppear {
            // Auto-expand sections that are small enough to show by default.
            for section in breakdown.sortedSections where section.isExpandableByDefault {
                expandedSections.insert(section.id)
            }
        }
    }

    // MARK: - Loading State

    private var loadingBody: some View {
        VStack(spacing: 16) {
            HermesProgressView()
                .scaleEffect(1.2)
            Text("Loading prompt breakdown…")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                contextUsageBar
                searchField

                if searchText.isEmpty {
                    allSectionsRows
                } else {
                    filteredSectionsRows
                }

                bottomSections
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .navigationTitle("Prompt Breakdown")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Context Usage Bar

    private var contextUsageBar: some View {
        VStack(spacing: 8) {
            // Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Available (gray background)
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Theme.surfaceHover)
                        .frame(height: 24)

                    // Used segments
                    HStack(spacing: 0) {
                        ForEach(breakdown.sortedSections) { section in
                            let width = barWidth(section.tokenCount, totalWidth: geo.size.width)
                            Rectangle()
                                .fill(section.color)
                                .frame(width: width, height: 24)
                        }

                        // Tools segment
                        let toolsWidth = barWidth(breakdown.toolDefinitionsTokenCount, totalWidth: geo.size.width)
                        Rectangle()
                            .fill(Theme.secondary)
                            .frame(width: toolsWidth, height: 24)

                        // History segment
                        let historyWidth = barWidth(breakdown.conversationHistoryTokenCount, totalWidth: geo.size.width)
                        Rectangle()
                            .fill(Theme.tertiary)
                            .frame(width: historyWidth, height: 24)
                    }
                    .mask(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(height: 24)

            // Label
            HStack {
                Text(formattedTokenUsage)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)

                Spacer()

                Text("\(formattedPercent) of \(formattedContextLimit) context")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func barWidth(_ tokens: Int, totalWidth: CGFloat) -> CGFloat {
        guard breakdown.contextLimit > 0, tokens > 0 else { return 0 }
        return max(CGFloat(tokens) / CGFloat(breakdown.contextLimit) * totalWidth, 2)
    }

    // MARK: - Search

    @ViewBuilder
    private var searchField: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.tertiary)
                    .font(.subheadline)

                TextField("Search prompt content…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(Theme.primary)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.tertiary)
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))

            // Match summary
            if !searchText.isEmpty {
                let matchCount = matchedSectionIDs.count
                HStack {
                    Text("\(matchCount) section\(matchCount == 1 ? "" : "s") match")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var matchedSectionIDs: Set<String> {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return Set(breakdown.sortedSections.filter { section in
            section.fullContent.lowercased().contains(query) || section.name.lowercased().contains(query)
        }.map(\.id))
    }

    private var filteredSections: [PromptSection] {
        guard !searchText.isEmpty else { return breakdown.sortedSections }
        let query = searchText.lowercased()
        return breakdown.sortedSections.filter { section in
            section.fullContent.lowercased().contains(query) || section.name.lowercased().contains(query)
        }
    }

    // MARK: - Section Rows (All)

    private var allSectionsRows: some View {
        VStack(spacing: 0) {
            sectionHeader(count: breakdown.sortedSections.count)
            ForEach(breakdown.sortedSections) { section in
                SectionRowView(
                    section: section,
                    isExpanded: expandedSections.contains(section.id),
                    searchText: "",
                    onToggle: { toggleSection(section.id) }
                )
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Filtered Section Rows

    private var filteredSectionsRows: some View {
        VStack(spacing: 0) {
            sectionHeader(count: filteredSections.count)
            ForEach(filteredSections) { section in
                SectionRowView(
                    section: section,
                    isExpanded: true, // auto-expand search matches
                    searchText: searchText,
                    onToggle: { toggleSection(section.id) }
                )
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionHeader(count: Int) -> some View {
        HStack {
            Text("SYSTEM PROMPT SECTIONS")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
            Spacer()
            Text("\(count) section\(count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.background.opacity(0.5))
    }

    private func toggleSection(_ id: String) {
        if expandedSections.contains(id) {
            expandedSections.remove(id)
        } else {
            expandedSections.insert(id)
        }
    }

    // MARK: - Bottom Sections

    private var bottomSections: some View {
        VStack(spacing: 12) {
            // Tool Definitions
            VStack(spacing: 0) {
                bottomSectionRow(
                    icon: "wrench.and.screwdriver",
                    title: "Tool Definitions",
                    subtitle: "\(breakdown.toolDefinitionsCount) tools · \(formattedTokens(breakdown.toolDefinitionsTokenCount))",
                    color: Theme.secondary,
                    isExpanded: expandedSections.contains("__tools__"),
                    onToggle: { toggleSection("__tools__") }
                )

                if expandedSections.contains("__tools__") {
                    toolDefinitionsContent
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))

            // Conversation History
            VStack(spacing: 0) {
                bottomSectionRow(
                    icon: "bubble.left.and.bubble.right",
                    title: "Conversation History",
                    subtitle: "\(breakdown.conversationHistoryMessageCount) messages · \(formattedTokens(breakdown.conversationHistoryTokenCount))",
                    color: Theme.tertiary,
                    isExpanded: false,
                    onToggle: { /* not expandable */ }
                )
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func bottomSectionRow(
        icon: String,
        title: String,
        subtitle: String,
        color: Color,
        isExpanded: Bool,
        onToggle: @escaping () -> Void
    ) -> some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(color)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }

    private var toolDefinitionsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .background(Theme.border)

            // swiftlint:disable:next line_length
            Text("\(breakdown.toolDefinitionsCount) tool definitions are available for the agent to use. These include function signatures, parameter schemas, and descriptions consumed by the model's tool-calling capabilities.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 12)

            Text("\(formattedTokens(breakdown.toolDefinitionsTokenCount)) tokens — included in every request")
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Helpers

    private var formattedTokenUsage: String {
        "\(formattedNumber(breakdown.totalTokens)) / \(formattedNumber(breakdown.contextLimit)) tokens"
    }

    private var formattedPercent: String {
        String(format: "%.1f%%", breakdown.contextUsagePercent)
    }

    private var formattedContextLimit: String {
        formattedNumber(breakdown.contextLimit)
    }

    private func formattedTokens(_ count: Int) -> String {
        "\(formattedNumber(count)) tokens"
    }

    private func formattedNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Section Row View

private struct SectionRowView: View {
    let section: PromptSection
    let isExpanded: Bool
    let searchText: String
    let onToggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Theme.border)

            // Header row
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 12)

                    Circle()
                        .fill(section.color)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.primary)

                        Text(section.source)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text("\(formattedCount(section.tokenCount)) tokens")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceHover, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                expandedContent
            }
        }
        .background(sectionBackground, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }

    private var sectionBackground: Color {
        Theme.background.opacity(0.3)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .background(Theme.border)

            // Full content with optional highlighting
            if searchText.isEmpty {
                Text(section.fullContent)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
            } else {
                highlightedContent
            }

            // Footer: char count + copy
            HStack {
                Text("\(section.charCount) characters")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)

                Spacer()

                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(section.fullContent, forType: .string)
                    #else
                    UIPasteboard.general.string = section.fullContent
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var highlightedContent: some View {
        let query = searchText.lowercased()

        if query.isEmpty || !section.fullContent.lowercased().contains(query) {
            Text(section.fullContent)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
        } else {
            attributedHighlightedText(section.fullContent, query: query)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
        }
    }

    private func attributedHighlightedText(_ text: String, query: String) -> Text {
        let lower = text.lowercased()
        guard lower.contains(query) else {
            return Text(text).foregroundStyle(Theme.primary)
        }

        var result = Text("")
        var searchStart = lower.startIndex
        while let matchRange = lower[searchStart...].range(of: query) {
            // Text before match
            let beforeStart = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: searchStart))
            let beforeEnd = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: matchRange.lowerBound))
            if beforeStart < beforeEnd {
                // swiftlint:disable:next shorthand_operator
                result = result + Text(text[beforeStart..<beforeEnd]).foregroundStyle(Theme.primary)
            }

            // Highlighted match
            let highlightStart = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: matchRange.lowerBound))
            let highlightEnd = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: matchRange.upperBound))
                // swiftlint:disable:next shorthand_operator
            result = result + Text(text[highlightStart..<highlightEnd])
                .foregroundStyle(Color.yellow)
                .bold()

            searchStart = matchRange.upperBound
        }

        // Remaining text after last match
        let remainderStart = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: searchStart))
        if remainderStart < text.endIndex {
                // swiftlint:disable:next shorthand_operator
            result = result + Text(text[remainderStart...]).foregroundStyle(Theme.primary)
        }

        return result
    }

    private func formattedCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

// MARK: - Prompt Breakdown Sheet

/// Wrapper that loads the prompt breakdown from the gateway before presenting
/// the ``PromptBreakdownView``. Handles loading and error states.
struct PromptBreakdownSheet: View {
    let sessionID: String
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.dismiss) private var dismiss

    @State private var breakdown: PromptBreakdown?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                HermesProgressView(label: "Loading prompt breakdown…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            } else if let error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Cannot Load Prompt")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            } else if let breakdown {
                PromptBreakdownView(breakdown: breakdown)
            }
        }
        .task { await loadBreakdown() }
    }

    private func loadBreakdown() async {
        guard case .connected = gatewayClientWrapper.client.connectionState else {
            error = "Not connected to gateway."
            isLoading = false
            return
        }

        do {
            breakdown = try await gatewayClientWrapper.client.promptBreakdown(sessionID: sessionID)
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Mock Data") {
    PromptBreakdownView(breakdown: .mock)
        .preferredColorScheme(.dark)
}

#Preview("Loading") {
    PromptBreakdownView(breakdown: .mock, isLoading: true)
        .preferredColorScheme(.dark)
}
#endif
