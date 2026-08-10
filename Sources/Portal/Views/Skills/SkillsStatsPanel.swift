import SwiftUI

/// Aggregate tiles for the skills canvas: how many skills, folders, and sources
/// are in view.
///
/// The counts describe the *filtered* set, not the whole library, so the numbers
/// always agree with the list beside them — a "42 skills" tile above a list
/// showing three is worse than no tile at all. The total is shown alongside when
/// a filter is narrowing things, so the library size isn't lost.
@MainActor
internal struct SkillsStatsPanel: View {
    @EnvironmentObject private var filterState: SkillsFilterState
    internal let skills: [SkillInfo]

    private var visible: [SkillInfo] {
        filterState.filtered(skills)
    }

    internal var body: some View {
        let visible = self.visible
        let folders = SkillCategory.allPaths(in: visible).count
        let sources = Set(visible.map(\.source)).count
        return HStack(spacing: 0) {
            tile(
                value: "\(visible.count)",
                caption: filterState.hasActiveFilters ? "of \(skills.count) skills" : "Skills",
                color: Theme.accent
            )
            tile(value: "\(folders)", caption: folders == 1 ? "Folder" : "Folders", color: Theme.success)
            tile(value: "\(sources)", caption: sources == 1 ? "Source" : "Sources", color: Theme.warning)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func tile(value: String, caption: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(caption)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}
