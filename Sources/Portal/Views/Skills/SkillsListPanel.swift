import SwiftUI

/// The roll-down skill list as a canvas panel — the classic Skills view, filtered
/// by the shared `SkillsFilterState`.
///
/// Reuses `SkillCard` verbatim rather than reimplementing the row: the
/// expand-in-place behavior, install/uninstall lifecycle, Standard-mode enable
/// toggle, and on-device summary are all already correct there, and a second copy
/// would drift from the iOS view that still uses the original.
///
/// Expansion is the shared selection, not panel-local state: expanding a card and
/// inspecting a skill are the same intent, so the detail and editor panels follow
/// the card the user opened, and the folder tree opens the card it selects.
@MainActor
internal struct SkillsListPanel: View {
    @EnvironmentObject private var filterState: SkillsFilterState
    internal let viewModel: SkillsViewModel
    /// Rows are grouped under folder headers when true — the middle ground
    /// between a flat list and the full tree panel.
    internal var groupByCategory = true
    internal let onViewMarkdown: (SkillInfo) -> Void

    @State private var confirmUninstall: String?

    private var visible: [SkillInfo] {
        filterState.visible(viewModel.skills)
    }

    internal var body: some View {
        Group {
            if viewModel.isLoading && viewModel.skills.isEmpty {
                loadingState
            } else if visible.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if groupByCategory {
                            groupedRows
                        } else {
                            ForEach(visible) { skill in
                                card(skill)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Rows

    /// Grouped by the skill's full category path (not the tree), so a sorted,
    /// searched list still reads with its headings intact.
    @ViewBuilder
    private var groupedRows: some View {
        let groups = Dictionary(grouping: visible) { $0.category }
        ForEach(groups.keys.sorted(), id: \.self) { category in
            if let skills = groups[category] {
                Text(category.isEmpty ? "Uncategorized" : SkillCategory.displayPath(SkillCategory.split(category: category)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.top, 2)
                ForEach(skills) { skill in
                    card(skill)
                }
            }
        }
    }

    private func card(_ skill: SkillInfo) -> some View {
        SkillCard(
            skill: skill,
            isExpanded: filterState.selectedSkillName == skill.name,
            installStatus: viewModel.installStatus[skill.name],
            summaryState: viewModel.skillSummaries[skill.name],
            confirmUninstall: confirmUninstall == skill.name,
            isStandardMode: viewModel.isStandardMode,
            isEnabled: viewModel.standardEnabled[skill.name] ?? true,
            onSetEnabled: { _ in
                Task { await viewModel.toggleStandardSkill(name: skill.name) }
            },
            onToggle: {
                let expanding = filterState.selectedSkillName != skill.name
                withAnimation(.easeInOut(duration: 0.18)) {
                    filterState.selectedSkillName = expanding ? skill.name : nil
                }
                if expanding {
                    Task { await viewModel.requestSummary(for: skill) }
                }
            },
            onRequestSummary: {
                Task { await viewModel.requestSummary(for: skill) }
            },
            onUninstall: {
                // Two-step: the first press arms, the second commits. Same
                // contract as the original view — an uninstall is unrecoverable
                // without a reinstall from the hub.
                if confirmUninstall == skill.name {
                    confirmUninstall = nil
                    Task { await viewModel.uninstallSkill(name: skill.name) }
                } else {
                    confirmUninstall = skill.name
                }
            },
            onCancelUninstall: { confirmUninstall = nil },
            onViewMarkdown: { onViewMarkdown(skill) }
        )
        .id(skill.id)
    }

    // MARK: - States

    private var loadingState: some View {
        HStack(spacing: 8) {
            PortalProgressView().scaleEffect(0.7)
            Text("Loading skills…")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.skills.isEmpty {
            PanelEmptyState(
                icon: viewModel.errorMessage != nil ? "wifi.exclamationmark" : "sparkles",
                message: viewModel.errorMessage != nil
                    ? "Could not load skills — check the connection and refresh"
                    : "No skills installed yet. Open the Hub panel to find some."
            )
        } else {
            // Skills exist but the filters hid them all — say so, and offer the
            // way out, rather than showing the same empty state as "none installed".
            VStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.tertiary)
                Text("No skills match the current filters")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                Button("Clear filters") {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.clearFilters() }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(12)
        }
    }
}
