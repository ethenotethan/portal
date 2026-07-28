import SwiftUI

struct SkillsView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var viewModel = SkillsViewModel()
    @State private var expandedSkill: String?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var confirmUninstall: String?
    @State private var showDiagnostics = false
    @State private var markdownSkill: SkillInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().background(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                    if !gatewayClientWrapper.isConnected {
                        connectionBanner
                    }
                    summaryBar
                    installedSection
                    hubSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .refreshable { await viewModel.reload() }
        }
        .background(Theme.background)
        .task {
            viewModel.setGatewayClient(gatewayClientWrapper.client)
            // Start the local summarization model loading (downloads on first
            // use) so summaries are ready by the time a card is expanded.
            SkillSummaryService.shared.warmUp()
            if gatewayClientWrapper.isConnected {
                await viewModel.refreshIfNeeded()
            }
        }
        .sheet(item: $markdownSkill) { skill in
            SkillMarkdownSheet(
                skill: skill,
                viewModel: viewModel
            )
        }
    }

    // MARK: - Connection Banner

    private var connectionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            Text("Gateway disconnected — skills unavailable")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Spacer()
        }
        .padding(10)
        .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Spacer()
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(10)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Skills")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            Spacer()

            Button {
                showDiagnostics.toggle()
            } label: {
                Image(systemName: "stethoscope")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Diagnostics")

            Button {
                Task { await viewModel.reload() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    // MARK: - Summary

    private var summaryBar: some View {
        HStack(spacing: 0) {
            summaryChip(value: "\(viewModel.totalSkills)", label: "Skills", color: Theme.accent)
            summaryChip(value: "\(viewModel.categoryCount)", label: "Categories", color: Theme.success)
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func summaryChip(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Installed Skills

    private var installedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Installed")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            if viewModel.isLoading {
                loadingState
            } else if viewModel.skills.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(viewModel.categories.keys.sorted(), id: \.self) { category in
                        if let skills = viewModel.categories[category] {
                            skillCategoryGroup(category: category, skills: skills)
                        }
                    }
                }
            }

            if showDiagnostics {
                diagnosticsPanel
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var loadingState: some View {
        HStack(spacing: 8) {
            PortalProgressView().scaleEffect(0.7)
            Text("Loading skills…")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: viewModel.errorMessage != nil ? "wifi.exclamationmark" : "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(Theme.tertiary)
            Text(viewModel.errorMessage != nil ? "Could not load skills" : "Your toolkit is ready to grow! 🌱")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text(viewModel.errorMessage != nil ? "Check your connection and tap Retry above." : "Search the Skills Hub below to discover and install your first superpower.")
                .font(.subheadline)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let raw = viewModel.lastRawResponse {
                Text("Debug: \(raw)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Diagnostics Panel

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)

            HStack(spacing: 8) {
                diagnosticButton("Test List", action: { await viewModel.runDiagnostic(.list) })
                diagnosticButton("Test Scan", action: { await viewModel.runDiagnostic(.scan) })
                diagnosticButton("Test Search", action: { await viewModel.runDiagnostic(.search) })
            }

            if let diag = viewModel.diagnosticResult {
                ScrollView {
                    Text(diag)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func diagnosticButton(_ title: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func skillCategoryGroup(category: String, skills: [SkillInfo]) -> some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            Text(category.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 2)

            ForEach(skills) { skill in
                SkillCard(
                    skill: skill,
                    isExpanded: expandedSkill == skill.id,
                    installStatus: viewModel.installStatus[skill.name],
                    summaryState: viewModel.skillSummaries[skill.name],
                    confirmUninstall: confirmUninstall == skill.name,
                    onToggle: {
                        let expanding = expandedSkill != skill.id
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedSkill = expanding ? skill.id : nil
                        }
                        if expanding {
                            Task { await viewModel.requestSummary(for: skill) }
                        }
                    },
                    onRequestSummary: {
                        Task { await viewModel.requestSummary(for: skill) }
                    },
                    onUninstall: {
                        if confirmUninstall == skill.name {
                            confirmUninstall = nil
                            Task { await viewModel.uninstallSkill(name: skill.name) }
                        } else {
                            confirmUninstall = skill.name
                        }
                    },
                    onCancelUninstall: {
                        confirmUninstall = nil
                    },
                    onViewMarkdown: {
                        markdownSkill = skill
                    }
                )
            }
        }
    }

    // MARK: - Skills Hub

    private var hubSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Skills Hub")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            HStack(spacing: 8) {
                TextField("Search skills hub...", text: $viewModel.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await viewModel.search() } }

                Button {
                    Task { await viewModel.search() }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if viewModel.isSearching {
                HStack(spacing: 8) {
                    PortalProgressView().scaleEffect(0.7)
                    Text("Searching...")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }

            if let searchError = viewModel.searchError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                    Text(searchError)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(8)
                .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }

            if !viewModel.searchResults.isEmpty {
                ForEach(viewModel.searchResults) { result in
                    HubResultRow(
                        result: result,
                        installStatus: viewModel.installStatus[result.name],
                        onInstall: { Task { await viewModel.installSkill(name: result.name) } }
                    )
                }
            } else if !viewModel.isSearching && viewModel.searchQuery.count >= 2 && viewModel.searchError == nil {
                Text("Keep exploring — try a different keyword 🔍")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Skill Card

struct SkillCard: View {
    let skill: SkillInfo
    let isExpanded: Bool
    let installStatus: String?
    let summaryState: SkillSummaryService.SummaryState?
    let confirmUninstall: Bool
    let onToggle: () -> Void
    let onRequestSummary: () -> Void
    let onUninstall: () -> Void
    let onCancelUninstall: () -> Void
    let onViewMarkdown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        Divider().background(Theme.border)
                        aboutSection
                        if skill.description.isEmpty {
                            Text("No description available")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.tertiary)
                                .italic()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            MarkdownContentView(text: skill.description)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button {
                            onViewMarkdown()
                        } label: {
                            Label("Edit Markdown", systemImage: "doc.text")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        if let dir = skill.skillDir {
                            detailRow("Directory", value: dir)
                        }
                        if let path = skill.skillMdPath {
                            detailRow("Path", value: path)
                        }
                        if !skill.tags.isEmpty {
                            detailRow("Tags", value: skill.tags.joined(separator: ", "))
                        }
                        detailRow("Source", value: skill.source)
                        detailRow("Command", value: skill.slashCommand)
                        uninstallButton
                    }
                    .padding(.top, 8)
                    .padding(.leading, 28)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
                }
        }
        .padding(10)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var extractiveFallback: String? {
        guard let markdown = skill.skillMdFullContent ?? skill.skillMdPreview, !markdown.isEmpty else {
            return nil
        }
        return SkillSummaryService.extractiveFallback(markdown: markdown)
    }

    @ViewBuilder
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About this skill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)

            switch summaryState {
            case .ready(let summary):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                    // Full block renderer: summaries contain headings, tables,
                    // and lists. MarkdownText is inline-only and leaves ### etc.
                    // as raw text.
                    MarkdownContentView(text: summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("AI summary · on-device")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            case .generating:
                if let fallback = extractiveFallback {
                    fallbackText(fallback)
                }
                HStack(spacing: 6) {
                    PortalProgressView().scaleEffect(0.5)
                    Text(SkillSummaryService.shared.isModelReady
                         ? "Summarizing with local model…"
                         : "Preparing local model (downloads ~600MB on first use)…")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
            case .failed(let message):
                if let fallback = extractiveFallback {
                    fallbackText(fallback)
                }
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Button("Retry summary") {
                    onRequestSummary()
                }
                .font(.caption2)
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.accent)
            case .idle, nil:
                if let fallback = extractiveFallback {
                    fallbackText(fallback)
                }
            }
        }
    }

    private func fallbackText(_ text: String) -> some View {
        MarkdownContentView(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Flatten markdown to a single line of plain text for the collapsed
    /// card preview: drop heading/blockquote/list markers and emphasis so a
    /// truncated one-liner doesn't show raw `###`, `**`, `` ` ``.
    static func plainPreview(_ markdown: String) -> String {
        var line = markdown
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? markdown
        line = line.replacingOccurrences(
            of: #"^\s{0,3}(#{1,6}\s+|>\s+|[-*+]\s+|\d+\.\s+)"#,
            with: "", options: .regularExpression)
        for token in ["**", "__", "`", "*", "_", "~~"] {
            line = line.replacingOccurrences(of: token, with: "")
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 14)

            Image(systemName: sourceIcon)
                .font(.body)
                .foregroundStyle(sourceColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(skill.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    if !skill.slashCommand.isEmpty {
                        Text(skill.slashCommand)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12))
                            .foregroundStyle(Theme.accent)
                            .clipShape(Capsule())
                    }

                    Text(skill.source)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(sourceColor.opacity(0.12))
                        .foregroundStyle(sourceColor)
                        .clipShape(Capsule())
                }

                if !skill.description.isEmpty && !isExpanded {
                    // Collapsed one-liner: strip markdown syntax to plain text
                    // rather than render blocks in a single truncated line.
                    Text(Self.plainPreview(skill.description))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let status = installStatus {
                if status == "installing" || status == "uninstalling" {
                    PortalProgressView().scaleEffect(0.7)
                } else if status == "installed" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                } else if status.hasPrefix("failed") {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var sourceIcon: String {
        switch skill.source {
        case "official": "checkmark.seal.fill"
        case "github": "chevron.left.forwardslash.chevron.right"
        default: "sparkles"
        }
    }

    private var sourceColor: Color {
        switch skill.source {
        case "official": Theme.success
        case "github": Theme.accent
        default: .secondary
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }

    private var uninstallButton: some View {
        HStack(spacing: 8) {
            if confirmUninstall {
                Button("Confirm Uninstall", role: .destructive) {
                    onUninstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Cancel") {
                    onCancelUninstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button(role: .destructive) {
                    onUninstall()
                } label: {
                    Label("Uninstall", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Skill Markdown Sheet

private struct SkillMarkdownSheet: View {
    let skill: SkillInfo
    var viewModel: SkillsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var loadError: String?
    @State private var hasChanges = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let saveError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text(saveError).font(.caption)
                        Spacer()
                        Button("Dismiss") { self.saveError = nil }.font(.caption)
                    }
                    .padding(10)
                    .background(Color.red.opacity(0.06))
                }

                if isLoading {
                    Spacer()
                    PortalProgressView(label: "Loading markdown…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Spacer()
                } else if let loadError {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32)).foregroundStyle(Theme.tertiary)
                        Text("Could not load markdown")
                            .font(.headline).foregroundStyle(Theme.secondary)
                        Text(loadError)
                            .font(.caption).foregroundStyle(Theme.tertiary)
                            .multilineTextAlignment(.center).frame(maxWidth: 320)
                        Button("Retry") { Task { await loadMarkdown() } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if content.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 32)).foregroundStyle(Theme.tertiary)
                        Text("No markdown content")
                            .font(.headline).foregroundStyle(Theme.secondary)
                        Text("This skill does not have a SKILL.md file.")
                            .font(.caption).foregroundStyle(Theme.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    #if os(macOS)
                    HSplitView {
                        ScrollView {
                            MarkdownContentView(text: content)
                                .padding(20)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minWidth: 400)
                        .background(Theme.background)

                        VStack(spacing: 0) {
                            Text("Edit Markdown")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 6)
                            TextEditor(text: $content)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(Theme.primary)
                                .padding(8)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                                .onChange(of: content) { _, _ in hasChanges = true }
                        }
                        .frame(minWidth: 400)
                        .background(Theme.background)
                    }
                    #else
                    ScrollView {
                        MarkdownContentView(text: content)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    #endif
                }

                if isSaving {
                    PortalProgressView(label: "Saving…").padding(8)
                }
            }
            .background(Theme.background)
            .navigationTitle(skill.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !content.isEmpty {
                        Button("Save") {
                            Task { await saveMarkdown() }
                        }
                        .disabled(!hasChanges || isSaving)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(
            minWidth: (NSScreen.main?.visibleFrame.width ?? 1200) * 0.85,
            minHeight: (NSScreen.main?.visibleFrame.height ?? 800) * 0.85
        )
        #endif
        .background(Theme.background)
        .task { await loadMarkdown() }
    }

    private func loadMarkdown() async {
        isLoading = true
        loadError = nil

        if let cached = skill.skillMdFullContent, !cached.isEmpty {
            content = cached
            isLoading = false
            return
        }
        if let preview = skill.skillMdPreview, !preview.isEmpty {
            content = preview
        }

        guard let fetched = await viewModel.readSkillMarkdown(name: skill.name), !fetched.isEmpty else {
            loadError = "Gateway does not support reading SKILL.md content.\n\n" +
                "Ask your gateway administrator to implement `skills.manage` with " +
                "`action: \"read\"`, or check that the skill has a SKILL.md file."
            isLoading = false
            return
        }

        content = fetched
        hasChanges = false
        isLoading = false
    }

    private func saveMarkdown() async {
        isSaving = true
        saveError = nil
        let success = await viewModel.saveSkillMarkdown(name: skill.name, content: content)
        isSaving = false
        if success {
            hasChanges = false
        } else {
            saveError = "Failed to save. Check connection and try again."
        }
    }
}

// MARK: - Hub Result Row

private struct HubResultRow: View {
    let result: SkillSearchResult
    let installStatus: String?
    let onInstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.primary)
                if !result.description.isEmpty {
                    Text(result.description)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let status = installStatus {
                if status == "installing" {
                    PortalProgressView().scaleEffect(0.7)
                } else if status == "installed" {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .font(.caption)
                }
            } else {
                Button("Install") {
                    onInstall()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .font(.caption)
            }
        }
        .padding(8)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
    }
}
