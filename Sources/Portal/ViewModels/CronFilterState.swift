import Foundation

/// Filter + sort state for the Cron page, mirroring `SessionsFilterState` so a
/// cron reads like a specialized session: text search, status chips, a
/// time-window picker, and a sort menu. Cron-specific dimensions (a job's
/// enabled/paused state and last-run health) stand in for a session's live/ended
/// status. Cross-platform — the Cron page ships on both iOS and macOS.
@MainActor
internal final class CronFilterState: ObservableObject {
    @Published internal var searchText = ""
    @Published internal var filterStatus: FilterStatus = .all
    @Published internal var selectedTag: String?
    @Published internal var timeWindow: TimeWindow = .all
    @Published internal var sortOrder: SortOrder = .recent
    /// Group the list into the `CronCategory` tree (derived from `name` paths)
    /// instead of a flat list. Independent of `sortOrder`, which still orders
    /// jobs *within* each category level.
    @Published internal var groupByCategory = false
    /// Expanded category paths, keyed by `CronCategoryNode.id`. Collapsed by
    /// default so a deep tree opens as a readable top-level summary.
    @Published internal var expandedCategories: Set<String> = []

    // MARK: - Enums

    internal enum FilterStatus: String, CaseIterable {
        case all     = "All"
        case active  = "Active"
        case paused  = "Paused"
        case failing = "Failing"

        internal func matches(_ job: CronJob) -> Bool {
            switch self {
            case .all:     return true
            case .active:  return job.enabled && job.state != "paused"
            case .paused:  return !job.enabled || job.state == "paused"
            case .failing: return job.lastStatus == "error"
            }
        }
    }

    /// "Last run on or after" window, matched against a job's `lastRunAt`.
    internal enum TimeWindow: Equatable {
        case all
        case hour
        case day
        case week
        case month

        internal static var presets: [TimeWindow] { [.all, .hour, .day, .week, .month] }

        internal var label: String {
            switch self {
            case .all:   return "All time"
            case .hour:  return "Last hour"
            case .day:   return "Last 24h"
            case .week:  return "Last 7d"
            case .month: return "Last 30d"
            }
        }

        internal var cutoff: Date? {
            let now = Date()
            switch self {
            case .all:   return nil
            case .hour:  return now.addingTimeInterval(-3_600)
            case .day:   return now.addingTimeInterval(-86_400)
            case .week:  return now.addingTimeInterval(-604_800)
            case .month: return now.addingTimeInterval(-2_592_000)
            }
        }
    }

    internal enum SortOrder: String, CaseIterable {
        case recent = "Last run"
        case next   = "Next run"
        case name   = "Name"
    }

    // MARK: - Applying

    /// Filter + sort a job list. Text search covers the name, schedule, prompt,
    /// and delivery target so a job is findable by any visible facet.
    internal func apply(to jobs: [CronJob]) -> [CronJob] {
        var result = jobs.filter { filterStatus.matches($0) }

        if let selectedTag {
            result = result.filter { job in
                job.tags.contains { $0.localizedCaseInsensitiveCompare(selectedTag) == .orderedSame }
            }
        }

        if let cutoff = timeWindow.cutoff {
            result = result.filter { ($0.lastRunAt ?? .distantPast) >= cutoff }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            result = result.filter { matchesSearch($0, query: query) }
        }

        return sorted(result)
    }

    private func matchesSearch(_ job: CronJob, query: String) -> Bool {
        let haystack = [
            job.name,
            job.schedule,
            job.deliver,
            job.promptPreview ?? "",
            job.prompt ?? "",
        ] + job.tags
        return haystack.contains { $0.lowercased().contains(query) }
    }

    private func sorted(_ jobs: [CronJob]) -> [CronJob] {
        switch sortOrder {
        case .recent:
            return jobs.sorted { ($0.lastRunAt ?? .distantPast) > ($1.lastRunAt ?? .distantPast) }
        case .next:
            // Jobs with an upcoming run first (soonest at the top); the rest trail.
            return jobs.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }
        case .name:
            return jobs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - Counts (for chip badges)

    internal func count(for status: FilterStatus, in jobs: [CronJob]) -> Int {
        jobs.filter { status.matches($0) }.count
    }

    internal func availableTags(in jobs: [CronJob]) -> [String] {
        Array(Set(jobs.flatMap(\.tags))).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    // MARK: - Category grouping

    /// Filter + sort, then fold the result into the category tree. Grouping runs
    /// last so the active sort still governs row order within each level.
    internal func grouped(_ jobs: [CronJob]) -> CronCategoryGrouping {
        CronCategory.group(apply(to: jobs))
    }

    internal func isExpanded(_ node: CronCategoryNode) -> Bool {
        expandedCategories.contains(node.id)
    }

    internal func toggleExpanded(_ node: CronCategoryNode) {
        if expandedCategories.contains(node.id) {
            expandedCategories.remove(node.id)
        } else {
            expandedCategories.insert(node.id)
        }
    }

    /// Search matches inside a collapsed category would otherwise be invisible,
    /// so reveal every path that leads to a match while a query is active.
    internal func expandAll(in grouping: CronCategoryGrouping) {
        var paths: Set<String> = []
        func walk(_ node: CronCategoryNode) {
            paths.insert(node.id)
            node.children.forEach(walk)
        }
        grouping.roots.forEach(walk)
        expandedCategories = paths
    }
}
