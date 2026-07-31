import SwiftUI

/// The Cron page's grouped mode: an expand-in-place category tree over
/// `CronCategory` paths, with ungrouped jobs listed flat beneath it.
///
/// Rendered as flat rows with an indent per depth rather than nested
/// `DisclosureGroup`s — the enclosing `List` in `CronListView` supplies row
/// styling and swipe actions, and nesting real containers inside it would break
/// both. Row identity is the category path (or job id), so expansion state
/// survives a refresh.
internal struct CronCategoryTree: View {
    @ObservedObject internal var filterState: CronFilterState
    internal let grouping: CronCategoryGrouping
    /// Row builder for a job, supplied by the parent so the tree doesn't own
    /// navigation, context menus, or swipe actions.
    internal let jobRow: (CronJob) -> AnyView

    internal var body: some View {
        ForEach(grouping.rows(expanded: filterState.expandedCategories)) { row in
            switch row {
            case .category(let node, let depth, let isExpanded):
                CronCategoryHeaderRow(
                    node: node,
                    depth: depth,
                    isExpanded: isExpanded
                ) {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        filterState.toggleExpanded(node)
                    }
                }
            case .job(let job, let depth):
                jobRow(job)
                    .padding(.leading, CGFloat(depth) * 14)
            }
        }

        if !grouping.ungrouped.isEmpty {
            Section {
                ForEach(grouping.ungrouped) { job in
                    jobRow(job)
                }
            } header: {
                Text("Ungrouped")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.tertiary)
                    .textCase(nil)
            }
        }
    }
}

// MARK: - Header Row

/// One category level: disclosure chevron, name, and the subtree rollup count.
/// The count is `totalCount` (not `jobs.count`) so a collapsed parent still
/// summarizes everything beneath it — the point of the N-dimensional paths.
internal struct CronCategoryHeaderRow: View {
    internal let node: CronCategoryNode
    internal let depth: Int
    internal let isExpanded: Bool
    internal let onToggle: () -> Void

    internal var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 10)

                Image(systemName: depth == 0 ? "folder.fill" : "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.accent.opacity(depth == 0 ? 0.9 : 0.6))

                Text(node.name)
                    .font(.system(size: 12, weight: depth == 0 ? .semibold : .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(node.totalCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Theme.surface, in: Capsule())
            }
            .padding(.leading, CGFloat(depth) * 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
