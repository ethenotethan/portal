import SwiftUI

/// The skills canvas's folder view: an expand-in-place tree over `SkillCategory`
/// paths, with uncategorized skills listed flat beneath it.
///
/// Rendered as flat rows with an indent per depth rather than nested
/// `DisclosureGroup`s — same reason as `CronCategoryTree`: a recursive
/// `@ViewBuilder` can't infer its own opaque return type, and flat rows give
/// stable identity. Row identity is the folder path (or skill name), so both
/// expansion and selection survive a store refresh.
///
/// Clicking a folder *scopes* the list panel to it; clicking a skill selects it
/// for the detail and editor panels. The tree is navigation and filter at once.
@MainActor
internal struct SkillsFolderPanel: View {
    @EnvironmentObject private var filterState: SkillsFilterState
    /// Every skill, pre-search. The tree deliberately shows the FULL taxonomy
    /// rather than the searched subset: a folder tree that reshapes itself on
    /// every keystroke loses the structure it exists to convey. Search narrows
    /// the list panel; the tree stays put.
    internal let skills: [SkillInfo]

    /// Whether the one-time expand-all has run. Panel-local rather than part of
    /// `SkillsFilterState`: it's a display bootstrap, not shared filter state.
    @State private var didSeedExpansion = false

    private var grouping: SkillCategoryGrouping {
        SkillCategory.group(skills)
    }

    internal var body: some View {
        let grouping = self.grouping
        return VStack(spacing: 0) {
            toolbar(grouping)
            Divider().overlay(Theme.border.opacity(0.5))
            if grouping.isEmpty {
                PanelEmptyState(icon: "folder", message: "No skills to organize yet")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(grouping.rows(expanded: filterState.expandedFolders)) { row in
                            switch row {
                            case .folder(let node, let depth, let isExpanded):
                                folderRow(node, depth: depth, isExpanded: isExpanded)
                            case .skill(let skill, let depth):
                                skillRow(skill, depth: depth)
                            }
                        }

                        if !grouping.uncategorized.isEmpty {
                            uncategorizedSection(grouping.uncategorized)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.background)
        // Keyed on the skill count, not onAppear: on first appear the store is
        // usually still loading, so an onAppear seed would expand an empty tree
        // and then the real skills would arrive fully collapsed — which reads as
        // an empty panel rather than a closed tree.
        .onChange(of: skills.count, initial: true) { _, _ in
            guard !didSeedExpansion, !grouping.roots.isEmpty else { return }
            didSeedExpansion = true
            filterState.expandAll(in: grouping)
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ grouping: SkillCategoryGrouping) -> some View {
        HStack(spacing: 6) {
            if let scoped = filterState.scopedPath {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { filterState.scopedPath = nil }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                        Text(SkillCategory.displayPath(scoped))
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.15), in: Capsule())
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Clear the folder scope")
            } else {
                Text("\(skills.count) skills")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer(minLength: 4)

            Button {
                withAnimation(.easeInOut(duration: 0.12)) { filterState.expandAll(in: grouping) }
            } label: {
                Image(systemName: "chevron.down.square").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiary)
            .help("Expand all folders")

            Button {
                withAnimation(.easeInOut(duration: 0.12)) { filterState.collapseAll() }
            } label: {
                Image(systemName: "chevron.right.square").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiary)
            .help("Collapse all folders")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    // MARK: - Rows

    private func folderRow(_ node: SkillCategoryNode, depth: Int, isExpanded: Bool) -> some View {
        let isScoped = filterState.scopedPath == node.path
        return HStack(spacing: 6) {
            // The chevron is its own hit target: expanding a folder and scoping to
            // it are different intents, and one click can't mean both.
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { filterState.toggleExpanded(node) }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.12)) { filterState.toggleScope(to: node.path) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: depth == 0 ? "folder.fill" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent.opacity(depth == 0 ? 0.9 : 0.6))

                    Text(node.name)
                        .font(.system(size: 12, weight: depth == 0 ? .semibold : .medium))
                        .foregroundStyle(isScoped ? Theme.accent : Theme.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    // totalCount, not skills.count — a collapsed parent must still
                    // summarize everything beneath it. That rollup is the point of
                    // the N-dimensional paths.
                    Text("\(node.totalCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Theme.surface, in: Capsule())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Scope the list to \(SkillCategory.displayPath(node.path))")
        }
        .padding(.leading, CGFloat(depth) * 12)
        .padding(.vertical, 2)
        .background(isScoped ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private func skillRow(_ skill: SkillInfo, depth: Int) -> some View {
        let isSelected = filterState.selectedSkillName == skill.name
        return Button {
            filterState.selectedSkillName = skill.name
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                Text(skill.name)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
            }
            .padding(.leading, CGFloat(depth) * 12 + 12)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Theme.accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
    }

    private func uncategorizedSection(_ skills: [SkillInfo]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Uncategorized")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 6)
                .padding(.leading, 4)
            ForEach(skills) { skill in
                skillRow(skill, depth: 0)
            }
        }
    }
}
