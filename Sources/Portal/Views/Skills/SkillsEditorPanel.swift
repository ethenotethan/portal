import SwiftUI

/// In-canvas SKILL.md editor — the sheet version (`SkillMarkdownSheet`) rendered
/// as a panel, so editing a skill's markdown sits beside the folder tree and list
/// instead of covering them.
///
/// The panel *pins* the skill it is editing rather than tracking the selection
/// blindly. Following the selection while edits are unsaved would silently
/// discard them the moment someone clicks another row in the tree, so a moved
/// selection surfaces a "switch?" bar and the buffer stays put until the user
/// says otherwise.
@MainActor
internal struct SkillsEditorPanel: View {
    @EnvironmentObject private var filterState: SkillsFilterState
    internal let viewModel: SkillsViewModel

    /// The skill whose markdown is in `content`. Distinct from the canvas
    /// selection — see the type doc.
    @State private var pinnedName: String?
    @State private var content = ""
    /// The markdown as last loaded or saved. `hasChanges` is derived from this
    /// rather than latched by an `onChange` hook: assigning `content` during a
    /// load fires `onChange` *after* the load function returns, so a latched flag
    /// would arm itself on every fresh load and offer to save an untouched file.
    @State private var baseline = ""
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var showPreview = true

    private var hasChanges: Bool { content != baseline }

    private var selectedSkill: SkillInfo? {
        guard let name = filterState.selectedSkillName else { return nil }
        return viewModel.skills.first { $0.name == name }
    }

    private var pinnedSkill: SkillInfo? {
        guard let pinnedName else { return nil }
        return viewModel.skills.first { $0.name == pinnedName }
    }

    /// True when the canvas selection has moved off the pinned buffer.
    private var selectionDiverged: Bool {
        guard let selected = filterState.selectedSkillName, let pinnedName else { return false }
        return selected != pinnedName
    }

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let saveError {
                banner(saveError, icon: "exclamationmark.triangle.fill", color: .red) {
                    self.saveError = nil
                }
            }
            if selectionDiverged, let selected = selectedSkill {
                switchBar(to: selected)
            }
            Divider().overlay(Theme.border.opacity(0.5))
            editorBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: filterState.selectedSkillName) {
            // Auto-follow only while there is nothing to lose. Once the buffer is
            // dirty the user drives the switch via `switchBar`.
            guard !hasChanges, let selected = filterState.selectedSkillName, selected != pinnedName else { return }
            await load(name: selected)
        }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
            Text(pinnedName ?? "No skill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            if hasChanges {
                Circle()
                    .fill(Theme.warning)
                    .frame(width: 5, height: 5)
                    .help("Unsaved changes")
            }

            Spacer(minLength: 4)

            if isSaving {
                PortalProgressView().scaleEffect(0.5)
            }

            #if os(macOS)
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { showPreview.toggle() }
            } label: {
                Image(systemName: showPreview ? "sidebar.squares.left" : "square")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showPreview ? Theme.accent : Theme.secondary)
            .help(showPreview ? "Hide the rendered preview" : "Show the rendered preview")
            #endif

            Button {
                Task { await save() }
            } label: {
                Text("Save")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasChanges ? Theme.accent : Theme.tertiary)
            .disabled(!hasChanges || isSaving || viewModel.isStandardMode)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Theme.surface.opacity(0.4))
    }

    private func switchBar(to skill: SkillInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warning)
            Text("Unsaved edits here — selection moved to \(skill.name)")
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Discard & switch") {
                Task { await load(name: skill.name) }
            }
            .font(.caption2)
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Theme.warning.opacity(0.08))
    }

    private func banner(_ message: String, icon: String, color: Color, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            Text(message).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(2)
            Spacer(minLength: 4)
            Button("Dismiss", action: dismiss)
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
    }

    // MARK: - Body

    @ViewBuilder
    private var editorBody: some View {
        if viewModel.isStandardMode {
            PanelEmptyState(
                icon: "lock",
                message: "Editing SKILL.md needs a Gateway harness — a Standard backend has no write endpoint"
            )
        } else if pinnedSkill == nil {
            PanelEmptyState(icon: "doc.text", message: "Select a skill to edit its SKILL.md")
        } else if isLoading {
            PortalProgressView(label: "Loading markdown…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.tertiary)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                if let pinnedName {
                    Button("Retry") { Task { await load(name: pinnedName) } }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        } else {
            #if os(macOS)
            if showPreview {
                HSplitView {
                    previewPane
                    textPane
                }
            } else {
                textPane
            }
            #else
            textPane
            #endif
        }
    }

    private var previewPane: some View {
        ScrollView {
            MarkdownContentView(text: content)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 160)
        .background(Theme.background)
    }

    private var textPane: some View {
        TextEditor(text: $content)
            .font(.system(.caption, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.primary)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minWidth: 160)
            .background(Theme.background)
    }

    // MARK: - Load / save

    private func load(name: String) async {
        pinnedName = name
        isLoading = true
        loadError = nil
        saveError = nil
        defer { isLoading = false }

        guard let skill = viewModel.skills.first(where: { $0.name == name }) else {
            loadError = "Skill \"\(name)\" is no longer installed."
            content = ""
            baseline = ""
            return
        }

        if let cached = skill.skillMdFullContent, !cached.isEmpty {
            content = cached
            baseline = cached
            return
        }

        guard let fetched = await viewModel.readSkillMarkdown(name: name), !fetched.isEmpty else {
            let preview = skill.skillMdPreview ?? ""
            content = preview
            // Baseline = the preview, so a truncated preview can't be saved back
            // over the real file unless the user actually edits it.
            baseline = preview
            loadError = "Could not read SKILL.md. The harness may not support "
                + "`skills.manage` with `action: \"read\"`, or the skill has no SKILL.md."
            return
        }

        content = fetched
        baseline = fetched
    }

    private func save() async {
        guard let pinnedName, hasChanges else { return }
        isSaving = true
        saveError = nil
        let saved = content
        let success = await viewModel.saveSkillMarkdown(name: pinnedName, content: saved)
        isSaving = false
        if success {
            // Baseline the text that was actually sent, not `content` — the user
            // may have typed while the write was in flight, and those keystrokes
            // are still unsaved.
            baseline = saved
        } else {
            saveError = "Failed to save \(pinnedName). Check the connection and try again."
        }
    }
}
