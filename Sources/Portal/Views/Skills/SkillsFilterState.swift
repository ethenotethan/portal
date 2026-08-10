import Foundation

/// Global filter state for the skills canvas. Owned by `SkillsCanvasView` and
/// injected into every panel — the search panel drives it; the list, folder tree,
/// stats, and detail panels consume it. Mirrors `SessionsFilterState` so the three
/// canvas surfaces (sessions, cron, skills) behave identically.
///
/// The selection lives here rather than in a panel because it is *shared*: clicking
/// a skill in the folder tree must drive the detail and editor panels, and a panel
/// that owned the selection privately could not do that.
@MainActor
internal final class SkillsFilterState: ObservableObject {
    @Published internal var searchText = ""
    @Published internal var filterSource: String?
    @Published internal var sortOrder: SortOrder = .name
    /// Name of the skill selected on the canvas. `SkillInfo.id` IS the name, so
    /// this survives a store refresh that replaces the struct instances.
    @Published internal var selectedSkillName: String?
    /// Which folder rows are open in the tree panel. Keyed by
    /// `SkillCategoryNode.id` (the joined path), so expansion survives a refresh.
    @Published internal var expandedFolders: Set<String> = []
    /// Folder path the list panel is scoped to, or nil for "everything". Set by
    /// clicking a folder row — the tree acts as a filter for the list beside it.
    @Published internal var scopedPath: [String]?

    // MARK: - Enums

    internal enum SortOrder: String, CaseIterable, Codable {
        case name     = "Name"
        case category = "Category"
        case source   = "Source"
    }

    // MARK: - Expansion

    internal func toggleExpanded(_ node: SkillCategoryNode) {
        if expandedFolders.contains(node.id) {
            expandedFolders.remove(node.id)
        } else {
            expandedFolders.insert(node.id)
        }
    }

    /// Open every folder in a grouping. Called when the tree is first shown:
    /// presenting it fully collapsed hides every skill, which reads as an empty
    /// panel rather than a closed tree.
    internal func expandAll(in grouping: SkillCategoryGrouping) {
        expandedFolders = grouping.allFolderIDs
    }

    internal func collapseAll() {
        expandedFolders = []
    }

    // MARK: - Scoping

    /// Scope the list to a folder, or clear the scope by selecting it again.
    /// Toggling rather than always-setting means the tree row is also the way OUT
    /// of a scope — otherwise the only escape is a separate "clear" affordance the
    /// user has to find.
    internal func toggleScope(to path: [String]) {
        scopedPath = (scopedPath == path) ? nil : path
    }

    /// Whether `skill` lies inside the active scope. A scope matches the folder
    /// AND everything nested below it, so scoping to `writing` includes
    /// `writing/blog` — the rollup counts in the tree would otherwise disagree
    /// with the list beside them.
    internal func matchesScope(_ skill: SkillInfo) -> Bool {
        guard let scopedPath, !scopedPath.isEmpty else { return true }
        let path = SkillCategory.path(for: skill)
        guard path.count >= scopedPath.count else { return false }
        return Array(path.prefix(scopedPath.count)) == scopedPath
    }

    // MARK: - Filtering

    /// Apply search, source, and scope filters. Text search covers the name,
    /// description, slash command, and tags — the four things a user might
    /// remember about a skill — so searching "review" finds `/code-review` by its
    /// command as readily as by its name.
    internal func filtered(_ skills: [SkillInfo]) -> [SkillInfo] {
        var result = skills

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            result = result.filter { skill in
                skill.name.lowercased().contains(query)
                    || skill.description.lowercased().contains(query)
                    || skill.slashCommand.lowercased().contains(query)
                    || skill.category.lowercased().contains(query)
                    || skill.tags.contains { $0.lowercased().contains(query) }
            }
        }

        if let filterSource {
            result = result.filter { $0.source == filterSource }
        }

        if scopedPath != nil {
            result = result.filter { matchesScope($0) }
        }

        return result
    }

    /// Sort a pre-filtered skill array according to `sortOrder`. Every comparison
    /// falls back to the name so the order is total — otherwise skills sharing a
    /// category shuffle between renders.
    internal func sorted(_ skills: [SkillInfo]) -> [SkillInfo] {
        switch sortOrder {
        case .name:
            return skills.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .category:
            return skills.sorted { lhs, rhs in
                if lhs.category != rhs.category {
                    return lhs.category.localizedCaseInsensitiveCompare(rhs.category) == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        case .source:
            return skills.sorted { lhs, rhs in
                if lhs.source != rhs.source {
                    return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    /// Filter then sort — what every panel actually wants.
    internal func visible(_ skills: [SkillInfo]) -> [SkillInfo] {
        sorted(filtered(skills))
    }

    /// True when any filter is narrowing the set, so the chrome can offer a
    /// "clear" affordance only when there is something to clear.
    internal var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
            || filterSource != nil
            || scopedPath != nil
    }

    internal func clearFilters() {
        searchText = ""
        filterSource = nil
        scopedPath = nil
    }
}
