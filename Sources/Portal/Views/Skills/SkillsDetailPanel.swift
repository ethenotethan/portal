import SwiftUI

/// Inspector for the skill selected anywhere on the canvas — the folder tree, the
/// list, or the hub after an install.
///
/// Deliberately the *read* surface: metadata, tags, filesystem paths, the
/// description, and the on-device AI summary. Editing lives in
/// `SkillsEditorPanel`, so an inspector can sit permanently on the canvas without
/// carrying unsaved state around.
@MainActor
internal struct SkillsDetailPanel: View {
    @EnvironmentObject private var filterState: SkillsFilterState
    internal let viewModel: SkillsViewModel

    private var skill: SkillInfo? {
        guard let name = filterState.selectedSkillName else { return nil }
        // Resolved by name against the live list rather than held as a struct
        // copy, so the panel follows a refresh instead of showing stale fields.
        return viewModel.skills.first { $0.name == name }
    }

    internal var body: some View {
        Group {
            if let skill {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header(skill)
                        Divider().overlay(Theme.border.opacity(0.5))
                        summarySection(skill)
                        descriptionSection(skill)
                        metadataSection(skill)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                PanelEmptyState(
                    icon: "sidebar.right",
                    message: "Select a skill to inspect it"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .task(id: filterState.selectedSkillName) {
            // Summaries are generated lazily and cached, so selecting a skill is
            // the right trigger: the inspector is the surface that shows one.
            if let skill {
                await viewModel.requestSummary(for: skill)
            }
        }
    }

    // MARK: - Sections

    private func header(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(skill.name)
                .font(.headline)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if !skill.slashCommand.isEmpty {
                    badge(skill.slashCommand, color: Theme.accent)
                }
                badge(skill.source, color: Theme.success)
                if !skill.category.isEmpty {
                    badge(SkillCategory.displayPath(SkillCategory.path(for: skill)), color: Theme.warning)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About this skill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)

            switch viewModel.skillSummaries[skill.name] {
            case .ready(let summary):
                MarkdownContentView(text: summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("AI summary · on-device")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            case .generating:
                HStack(spacing: 6) {
                    PortalProgressView().scaleEffect(0.5)
                    Text(SkillSummaryService.shared.isModelReady
                         ? "Summarizing with local model…"
                         : "Preparing local model…")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
            case .failed(let message):
                if let fallback = extractiveFallback(skill) {
                    MarkdownContentView(text: fallback)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(3)
                }
                Button("Retry summary") {
                    Task { await viewModel.requestSummary(for: skill) }
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            case .idle, nil:
                if let fallback = extractiveFallback(skill) {
                    MarkdownContentView(text: fallback)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func descriptionSection(_ skill: SkillInfo) -> some View {
        if !skill.description.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Description")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                MarkdownContentView(text: skill.description)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metadataSection(_ skill: SkillInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 4)
            if !skill.tags.isEmpty {
                row("Tags", skill.tags.joined(separator: ", "))
            }
            if let identifier = skill.identifier {
                row("Identifier", identifier)
            }
            if let dir = skill.skillDir {
                row("Directory", dir)
            }
            if let path = skill.skillMdPath {
                row("Path", path)
            }
            row("Source", skill.source)
            row("Command", skill.slashCommand)
        }
    }

    // MARK: - Helpers

    private func extractiveFallback(_ skill: SkillInfo) -> String? {
        guard let markdown = skill.skillMdFullContent ?? skill.skillMdPreview, !markdown.isEmpty else {
            return nil
        }
        return SkillSummaryService.extractiveFallback(markdown: markdown)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
    }
}
