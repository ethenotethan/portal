import Foundation

/// N-dimensional folder paths for skills, derived from the skill's own category.
///
/// Same contract as `CronCategory`, for the same reason: the category string is
/// the one surface humans and agents already share, so a skill files itself into
/// `writing/blog` with no schema change and no hidden state. Depth is arbitrary
/// and every level rolls up, so "how many skills under `writing`?" is answerable
/// without enumerating leaves.
///
/// Skills whose category is empty are *uncategorized* rather than guessed at — an
/// inferred folder that files a skill wrongly is worse than an honest flat list.
internal enum SkillCategory {

    /// Path separator inside a category string. `/` reads as a path to humans and
    /// matches the cron convention, so one mental model covers both surfaces.
    internal static let separator: Character = "/"

    /// Split a category string into its path components.
    ///
    /// `"writing/blog"` → `["writing", "blog"]`
    /// `"general"` → `["general"]`
    /// `""` → `[]`
    ///
    /// Empty and whitespace-only components are dropped, so `"writing//blog/"`
    /// normalizes to `["writing", "blog"]` — an agent concatenating fragments
    /// shouldn't produce phantom levels.
    internal static func split(category: String) -> [String] {
        category
            .split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The folder path for a skill (empty when uncategorized).
    internal static func path(for skill: SkillInfo) -> [String] {
        split(category: skill.category)
    }

    /// Whether a skill carries no usable category.
    internal static func isUncategorized(_ skill: SkillInfo) -> Bool {
        path(for: skill).isEmpty
    }

    /// Every folder path present in `skills`, including intermediate levels,
    /// sorted shallowest-first then alphabetically. Intermediates are included
    /// (`writing` when only `writing/blog` holds skills) because navigating to a
    /// parent level is as reasonable as navigating to a leaf.
    internal static func allPaths(in skills: [SkillInfo]) -> [[String]] {
        var seen: Set<[String]> = []
        for skill in skills {
            let path = Self.path(for: skill)
            guard !path.isEmpty else { continue }
            for depth in 1...path.count {
                seen.insert(Array(path.prefix(depth)))
            }
        }
        return seen.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count < rhs.count }
            for (l, r) in zip(lhs, rhs) where l != r {
                return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
            }
            return false
        }
    }

    /// A path rendered for display: `["writing", "blog"]` → `"writing › blog"`,
    /// and the root as "Uncategorized" so an empty path is never a blank row.
    internal static func displayPath(_ path: [String]) -> String {
        path.isEmpty ? "Uncategorized" : path.joined(separator: " › ")
    }
}

// MARK: - Tree

/// One node in the skill folder tree: a folder level, the skills sitting directly
/// at it, and its child folders. `totalCount` is the rollup over the whole
/// subtree, which is what makes depth summarization work — a collapsed `writing`
/// still reports every skill beneath it.
internal struct SkillCategoryNode: Identifiable, Equatable {
    /// Full path from the root, e.g. `["writing", "blog"]`. Unique, so it also
    /// serves as identity for SwiftUI and for expansion state.
    internal let path: [String]
    /// This level's own name — the last path component (`"blog"`).
    internal let name: String
    /// Skills whose category is exactly this path.
    internal let skills: [SkillInfo]
    /// Nested folders, sorted by name.
    internal let children: [SkillCategoryNode]

    internal var id: String { path.joined(separator: String(SkillCategory.separator)) }

    /// Every skill in this subtree, at any depth.
    internal var totalCount: Int {
        skills.count + children.reduce(0) { $0 + $1.totalCount }
    }

    /// Whether anything is nested below this node (drives the disclosure triangle
    /// — a leaf folder with only skills still expands to show them).
    internal var hasChildren: Bool {
        !children.isEmpty || !skills.isEmpty
    }
}

// MARK: - Grouping

/// The folder view's material: a folder forest plus the uncategorized remainder.
internal struct SkillCategoryGrouping: Equatable {
    internal let roots: [SkillCategoryNode]
    /// Skills with no category, listed flat below the tree so nothing disappears
    /// merely because it wasn't filed.
    internal let uncategorized: [SkillInfo]

    internal static let empty = SkillCategoryGrouping(roots: [], uncategorized: [])

    internal var isEmpty: Bool { roots.isEmpty && uncategorized.isEmpty }

    /// True when no skill carries a category — the tree adds nothing, so the view
    /// can fall back to a plain list.
    internal var hasNoCategories: Bool { roots.isEmpty }

    /// Every folder id in the forest, at every depth. Seeds "expand all" so
    /// opening the tree doesn't present a wall of collapsed roots.
    internal var allFolderIDs: Set<String> {
        var out: Set<String> = []
        func walk(_ node: SkillCategoryNode) {
            out.insert(node.id)
            node.children.forEach(walk)
        }
        roots.forEach(walk)
        return out
    }
}

// MARK: - Flattening

/// One rendered line in the folder tree. The tree is flattened to a row sequence
/// rather than recursed over in SwiftUI: a recursive `@ViewBuilder` can't infer
/// its own opaque return type, and a flat list is also what `ForEach` wants for
/// stable row identity.
internal enum SkillCategoryRow: Identifiable, Equatable {
    case folder(SkillCategoryNode, depth: Int, isExpanded: Bool)
    case skill(SkillInfo, depth: Int)

    internal var id: String {
        switch self {
        case .folder(let node, _, _): return "dir:\(node.id)"
        case .skill(let skill, _):    return "skill:\(skill.id)"
        }
    }
}

extension SkillCategoryGrouping {
    /// The visible rows for this grouping, honoring which folders are open.
    /// Collapsed folders contribute their header only — their subtree is omitted
    /// entirely, so a deep tree stays cheap to render.
    internal func rows(expanded: Set<String>) -> [SkillCategoryRow] {
        var out: [SkillCategoryRow] = []

        func walk(_ node: SkillCategoryNode, depth: Int) {
            let isExpanded = expanded.contains(node.id)
            out.append(.folder(node, depth: depth, isExpanded: isExpanded))
            guard isExpanded else { return }
            for skill in node.skills {
                out.append(.skill(skill, depth: depth + 1))
            }
            for child in node.children {
                walk(child, depth: depth + 1)
            }
        }

        roots.forEach { walk($0, depth: 0) }
        return out
    }
}

extension SkillCategory {

    /// Build the folder forest for a skill list.
    ///
    /// Skills arrive already filtered and sorted by `SkillsFilterState`; this
    /// preserves that relative order within each level rather than re-sorting, so
    /// the active sort still governs the rows a user sees. Only *folder* levels
    /// are sorted, alphabetically, since a folder has no sort key of its own.
    internal static func group(_ skills: [SkillInfo]) -> SkillCategoryGrouping {
        var uncategorized: [SkillInfo] = []
        // path → skills directly at that path, insertion order preserved.
        var skillsByPath: [[String]: [SkillInfo]] = [:]
        // Every path level that must exist as a node, including intermediates
        // that hold no skills of their own (`writing` when only `writing/blog` does).
        var allPaths: Set<[String]> = []

        for skill in skills {
            let path = Self.path(for: skill)
            if path.isEmpty {
                uncategorized.append(skill)
                continue
            }
            skillsByPath[path, default: []].append(skill)
            for depth in 1...path.count {
                allPaths.insert(Array(path.prefix(depth)))
            }
        }

        let roots = allPaths
            .filter { $0.count == 1 }
            .sorted { $0[0].localizedCaseInsensitiveCompare($1[0]) == .orderedAscending }
            .map { buildNode(path: $0, allPaths: allPaths, skillsByPath: skillsByPath) }

        return SkillCategoryGrouping(roots: roots, uncategorized: uncategorized)
    }

    /// Recursively assemble the node at `path` from the flattened path set.
    private static func buildNode(
        path: [String],
        allPaths: Set<[String]>,
        skillsByPath: [[String]: [SkillInfo]]
    ) -> SkillCategoryNode {
        let childPaths = allPaths
            .filter { $0.count == path.count + 1 && Array($0.prefix(path.count)) == path }
            .sorted { lhs, rhs in
                guard let l = lhs.last, let r = rhs.last else { return false }
                return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
            }

        let children = childPaths.map {
            buildNode(path: $0, allPaths: allPaths, skillsByPath: skillsByPath)
        }

        return SkillCategoryNode(
            path: path,
            name: path.last ?? "",
            skills: skillsByPath[path] ?? [],
            children: children
        )
    }
}
