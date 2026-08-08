import Foundation

/// N-dimensional category paths for cron jobs, derived from the job's own name.
///
/// The contract is deliberately just a naming convention — `life/training/morning-run`
/// means "category `life/training`, job `morning-run`" — because that is the one
/// surface both humans and agents already share:
///
/// - **Agents** need no new API: `cron.manage` has no category field, so a job
///   names itself into a category (`quality/ratchet`) with zero schema change.
/// - **Humans** read it as a path and retag by renaming, with no hidden state.
///
/// Depth is arbitrary: `life/training/cardio/intervals` nests four levels and
/// rolls up at every one, so "how much am I running under `life`?" is answerable
/// without enumerating leaves.
///
/// Jobs whose names contain no separator are *ungrouped* rather than guessed at —
/// an inferred category that files a job wrongly is worse than an honest flat list.
internal enum CronCategory {

    /// Path separator in a job name. `/` reads as a path to humans and is already
    /// how the repo's own cron bot names branches (`cron/quality-ratchet-…`).
    internal static let separator: Character = "/"

    /// Split a job name into its category path and leaf title.
    ///
    /// `"life/training/morning-run"` → `(["life", "training"], "morning-run")`
    /// `"db-backup"` → `([], "db-backup")`
    ///
    /// Empty and whitespace-only components are dropped so `"life//training/"`
    /// normalizes to `["life", "training"]` — agents concatenating path fragments
    /// shouldn't produce phantom levels. A name that is *only* separators has no
    /// usable title, so the original string is preserved as the title.
    internal static func split(name: String) -> (path: [String], title: String) {
        let parts = name
            .split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let title = parts.last else { return ([], name) }
        return (Array(parts.dropLast()), title)
    }

    /// The category path for a job (empty when ungrouped).
    internal static func path(for job: CronJob) -> [String] {
        split(name: job.name).path
    }

    /// The display title for a job — its name with the category prefix stripped,
    /// so a row under `life/training` reads `morning-run`, not the full path.
    internal static func title(for job: CronJob) -> String {
        split(name: job.name).title
    }

    /// Whether a job carries no category.
    internal static func isUngrouped(_ job: CronJob) -> Bool {
        path(for: job).isEmpty
    }

    /// The name to show for a job, given whether its category is already visible
    /// somewhere else on screen.
    ///
    /// `showingPath` is false exactly when the job sits under its own category
    /// headers: those headers are the path, so repeating it makes every child
    /// restate its parent (`autoresearch/ingest` beneath a folder named
    /// `autoresearch`). Flat and ungrouped rows pass true, because there the
    /// name is the only place the category appears at all.
    ///
    /// Lives here rather than in each view so the list page's row and the
    /// activity board's card can't drift apart on what a grouped job is called.
    internal static func displayName(for job: CronJob, showingPath: Bool) -> String {
        showingPath ? job.name : title(for: job)
    }

    // MARK: - Renaming == recategorizing

    /// Clean up a user-typed job name into the canonical path form, or nil when
    /// nothing usable is left.
    ///
    /// `" life / training /run "` → `"life/training/run"`, `"///"` → nil.
    ///
    /// This exists because renaming a job IS how it gets refiled: the category
    /// lives in the name, so the rename field is a path editor and typing
    /// `life/training/` or a stray double slash must not create phantom levels
    /// on the server. `split(name:)` normalizes on the way *in*; this normalizes
    /// on the way *out*, so the two agree.
    ///
    /// Unlike `split(name:)`, a name made only of separators is rejected rather
    /// than preserved: displaying a nonsense name the server already holds is
    /// harmless, but writing one is not.
    internal static func normalize(name: String) -> String? {
        let parts = name
            .split(separator: separator, omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: String(separator))
    }

    /// Whether `raw` is worth sending as the new name for a job currently named
    /// `current` — usable after normalizing, and actually a change. Drives the
    /// Save button so a no-op rename never costs a round trip and a refresh.
    internal static func isRenameable(_ raw: String, from current: String) -> Bool {
        guard let next = normalize(name: raw) else { return false }
        return next != current
    }

    // MARK: - Moving without retyping the name

    /// The full name that puts `name`'s leaf under `path`, keeping the leaf as-is.
    ///
    /// `("morning-run", ["life", "training"])` → `"life/training/morning-run"`
    /// `("life/training/run", [])` → `"run"` (move to Ungrouped)
    ///
    /// This is the counterpart to `split(name:)`: the editor used to make the
    /// user retype the whole path *including the leaf* just to relocate a job,
    /// which meant re-entering the job's identity to change its folder — and one
    /// typo silently renamed it instead of moving it. Destination and identity
    /// are separate concerns, so moving takes a path and preserves the leaf.
    ///
    /// Returns nil when the name has no usable leaf, so callers can't write a
    /// name that is only separators.
    internal static func moved(name: String, to path: [String]) -> String? {
        guard let leaf = normalize(name: name).map({ split(name: $0).title }) else { return nil }
        let cleanPath = path
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (cleanPath + [leaf]).joined(separator: String(separator))
    }

    /// Every category path present in `jobs`, including intermediate levels, each
    /// sorted shallowest-first then alphabetically.
    ///
    /// Powers the destination picker: the whole point is to *choose* an existing
    /// category rather than remember and retype it. Intermediates are included
    /// (`life` when only `life/training` holds jobs) because moving a job up one
    /// level is as reasonable as moving it down.
    internal static func allPaths(in jobs: [CronJob]) -> [[String]] {
        var seen: Set<[String]> = []
        for job in jobs {
            let path = Self.path(for: job)
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

    /// A path rendered for display: `["life", "training"]` → `"life › training"`,
    /// and the root as "Ungrouped" so an empty destination is never a blank row.
    internal static func displayPath(_ path: [String]) -> String {
        path.isEmpty ? "Ungrouped" : path.joined(separator: " › ")
    }

    // MARK: - The cost of overloading the name

    /// The categories a typed name would silently create, when it looks more like
    /// a title that happens to contain a slash than a deliberate path.
    ///
    /// This is the price of deriving the category from the name: `/` is reserved,
    /// so `A/B testing digest` files under a category named `A` and the job becomes
    /// `B testing digest`. That is a real thing to want to name a job, and the
    /// convention gives no way to escape the separator — so the least we can do is
    /// not let it happen silently.
    ///
    /// Returns nil when there's nothing to warn about. Two signals, both narrow,
    /// because a warning that fires on `life/training/morning-run` is worse than no
    /// warning at all — it trains the user to ignore it:
    ///
    /// 1. A *path* component containing a space (`A B/testing digest`). Categories
    ///    are slugs; prose in one means the slash wasn't meant as a separator.
    /// 2. A prose leaf under a 1–2 character category (`A/B testing digest`,
    ///    `I/O latency check`, `24/7 uptime probe`). Very short categories are
    ///    legitimate but rare, and paired with a spaced leaf they almost always
    ///    indicate an abbreviation that happens to contain a slash.
    ///
    /// Advisory only — callers warn, they don't block, because the user may
    /// genuinely mean it and the convention offers no way to escape the separator.
    internal static func separatorWarning(for raw: String) -> String? {
        guard let normalized = normalize(name: raw) else { return nil }
        let parts = normalized.split(separator: separator).map(String.init)
        guard parts.count > 1 else { return nil }

        let pathParts = Array(parts.dropLast())
        let leaf = parts[parts.count - 1]

        let proseInPath = pathParts.contains { $0.contains(" ") }
        let abbreviation = leaf.contains(" ") && pathParts.contains { $0.count <= 2 }
        guard proseInPath || abbreviation else { return nil }

        let categories = pathParts.joined(separator: " › ")
        return "“\(separator)” separates categories, so this files under \(categories). "
            + "Remove the slash if you meant it as part of the name."
    }
}

// MARK: - Tree

/// One node in the category tree: a category level, the jobs sitting directly at
/// it, and its child categories. `totalCount` is the rollup over the whole
/// subtree, which is what makes depth summarization work — a collapsed `life`
/// still reports every job beneath it.
internal struct CronCategoryNode: Identifiable, Equatable {
    /// Full path from the root, e.g. `["life", "training"]`. Unique, so it also
    /// serves as the identity for SwiftUI and for expansion state.
    internal let path: [String]
    /// This level's own name — the last path component (`"training"`).
    internal let name: String
    /// Jobs whose category is exactly this path.
    internal let jobs: [CronJob]
    /// Nested categories, sorted by name.
    internal let children: [CronCategoryNode]

    internal var id: String { path.joined(separator: String(CronCategory.separator)) }

    /// Every job in this subtree, at any depth.
    internal var totalCount: Int {
        jobs.count + children.reduce(0) { $0 + $1.totalCount }
    }

    /// Whether this node has anything nested below it (drives the disclosure
    /// triangle — a leaf category with only jobs still expands to show them).
    internal var hasChildren: Bool {
        !children.isEmpty || !jobs.isEmpty
    }
}

// MARK: - Grouping

/// The Cron page's grouped view: a category forest plus the ungrouped remainder.
internal struct CronCategoryGrouping: Equatable {
    internal let roots: [CronCategoryNode]
    /// Jobs with no category, listed flat below the tree so nothing disappears
    /// merely because it wasn't named with a path.
    internal let ungrouped: [CronJob]

    internal var isEmpty: Bool { roots.isEmpty && ungrouped.isEmpty }

    /// True when no job carries a category — the tree adds nothing, so the view
    /// can fall back to a plain list.
    internal var hasNoCategories: Bool { roots.isEmpty }
}

// MARK: - Flattening

/// One rendered line in the grouped Cron list. The tree is flattened to a row
/// sequence rather than recursed over in SwiftUI: a recursive `@ViewBuilder`
/// can't infer its own opaque return type, and a flat list is also what `List`
/// wants for stable row identity, swipe actions, and selection.
internal enum CronCategoryRow: Identifiable, Equatable {
    case category(CronCategoryNode, depth: Int, isExpanded: Bool)
    case job(CronJob, depth: Int)

    internal var id: String {
        switch self {
        case .category(let node, _, _): return "cat:\(node.id)"
        case .job(let job, _):          return "job:\(job.id)"
        }
    }
}

extension CronCategoryGrouping {
    /// The visible rows for this grouping, honoring which categories are open.
    /// Collapsed categories contribute their header only — their subtree is
    /// omitted entirely, so a deep tree stays cheap to render.
    internal func rows(expanded: Set<String>) -> [CronCategoryRow] {
        var out: [CronCategoryRow] = []

        func walk(_ node: CronCategoryNode, depth: Int) {
            let isExpanded = expanded.contains(node.id)
            out.append(.category(node, depth: depth, isExpanded: isExpanded))
            guard isExpanded else { return }
            for job in node.jobs {
                out.append(.job(job, depth: depth + 1))
            }
            for child in node.children {
                walk(child, depth: depth + 1)
            }
        }

        roots.forEach { walk($0, depth: 0) }
        return out
    }
}

extension CronCategory {

    /// Build the category forest for a job list.
    ///
    /// Jobs arrive already filtered and sorted by `CronFilterState`; this
    /// preserves that relative order within each level rather than re-sorting,
    /// so the active sort (last run / next run / name) still governs the rows a
    /// user sees. Only *category* levels are sorted, alphabetically, since a
    /// category has no run timestamps of its own to order by.
    internal static func group(_ jobs: [CronJob]) -> CronCategoryGrouping {
        var ungrouped: [CronJob] = []
        // path → jobs directly at that path, insertion order preserved.
        var jobsByPath: [[String]: [CronJob]] = [:]
        // Every path level that must exist as a node, including intermediates
        // that hold no jobs of their own (`life` when only `life/training` has any).
        var allPaths: Set<[String]> = []

        for job in jobs {
            let path = Self.path(for: job)
            if path.isEmpty {
                ungrouped.append(job)
                continue
            }
            jobsByPath[path, default: []].append(job)
            for depth in 1...path.count {
                allPaths.insert(Array(path.prefix(depth)))
            }
        }

        let roots = allPaths
            .filter { $0.count == 1 }
            .sorted { $0[0].localizedCaseInsensitiveCompare($1[0]) == .orderedAscending }
            .map { buildNode(path: $0, allPaths: allPaths, jobsByPath: jobsByPath) }

        return CronCategoryGrouping(roots: roots, ungrouped: ungrouped)
    }

    /// Recursively assemble the node at `path` from the flattened path set.
    private static func buildNode(
        path: [String],
        allPaths: Set<[String]>,
        jobsByPath: [[String]: [CronJob]]
    ) -> CronCategoryNode {
        let childPaths = allPaths
            .filter { $0.count == path.count + 1 && Array($0.prefix(path.count)) == path }
            .sorted { lhs, rhs in
                guard let l = lhs.last, let r = rhs.last else { return false }
                return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
            }

        let children = childPaths.map {
            buildNode(path: $0, allPaths: allPaths, jobsByPath: jobsByPath)
        }

        return CronCategoryNode(
            path: path,
            name: path.last ?? "",
            jobs: jobsByPath[path] ?? [],
            children: children
        )
    }
}
