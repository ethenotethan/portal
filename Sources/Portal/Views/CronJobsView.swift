import SwiftUI

/// The Cron Activity board's Jobs pane: category headers you expand to reach the
/// jobs filed under them, each an expandable `CronJobCard` with pause/resume/
/// remove/edit actions. Observes the run-history store for per-job stats.
///
/// Two deliberate differences from the flat list it replaced:
///
/// 1. **The title is the host's to draw** (`showsTitle`). On the macOS canvas
///    the panel chrome already renders the registry's `title: "Jobs"`, so an
///    in-body heading printed the same word twice on one pane. The iOS stack
///    has no chrome and labels each section itself, so it keeps the heading.
/// 2. **Grouped, collapsed by default.** A flat stack of cards was doing the
///    category namespacing (`quality/ratchet`, `life/training/…`) purely
///    visually, repeating the prefix on every row. The tree is the same
///    `CronCategory` grouping the Cron *list* page already uses, so a job files
///    identically in both places and rollup counts summarize a collapsed
///    subtree.
///
/// Rows are the shared `CronCategoryGrouping.rows(expanded:)` flattening and
/// `CronCategoryHeaderRow`, but the container is a `VStack` rather than
/// `CronCategoryTree`'s `List` — cards carry their own chrome here, and `List`
/// row styling would fight it.
internal struct CronJobsView: View {
    internal var vm: CronListViewModel
    /// Whether to draw an in-body "Jobs" heading. False on the macOS canvas,
    /// whose panel chrome supplies it (see the type doc).
    internal var showsTitle: Bool

    @ObservedObject private var store = CronRunHistoryStore.shared
    @State private var expandedJobID: String?
    /// Open category paths, keyed by `CronCategoryNode.id`. Collapsed by
    /// default: the point of the pane is to read as a set of categories you
    /// drill into, not the flat card stack it replaced.
    @State private var expandedCategories: Set<String> = []
    /// Real per-run execution ledgers fetched lazily from the gateway on
    /// expand (`cron.manage` action "history"), keyed by job id. These carry
    /// true durations the passively-observed store records lack.
    @State private var ledgers: [String: [CronRunRecord]] = [:]

    internal init(vm: CronListViewModel, showsTitle: Bool = true) {
        self.vm = vm
        self.showsTitle = showsTitle
    }

    private var grouping: CronCategoryGrouping {
        CronCategory.group(vm.jobs)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsTitle {
                Text("Jobs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }

            if vm.jobs.isEmpty {
                Text("No cron jobs")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let tree = grouping
                // Nothing carries a category — the tree would add a level of
                // indirection over a single "Ungrouped" heading, so stay flat.
                if tree.hasNoCategories {
                    ForEach(vm.jobs) { job in
                        card(for: job)
                    }
                } else {
                    categorizedRows(tree)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func categorizedRows(_ grouping: CronCategoryGrouping) -> some View {
        ForEach(grouping.rows(expanded: expandedCategories)) { row in
            switch row {
            case .category(let node, let depth, let isExpanded):
                CronCategoryHeaderRow(node: node, depth: depth, isExpanded: isExpanded) {
                    withAnimation(.easeInOut(duration: 0.12)) { toggle(node) }
                }
            case .job(let job, let depth):
                card(for: job)
                    .padding(.leading, CGFloat(depth) * 14)
            }
        }

        if !grouping.ungrouped.isEmpty {
            Text("Ungrouped")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 2)
            ForEach(grouping.ungrouped) { job in
                card(for: job)
            }
        }
    }

    private func card(for job: CronJob) -> CronJobCard {
        CronJobCard(
            job: job,
            isExpanded: expandedJobID == job.id,
            runRecords: records(for: job.id),
            onToggle: { toggle(job) },
            onPause: { Task { await vm.pauseJob(id: job.id) } },
            onResume: { Task { await vm.resumeJob(id: job.id) } },
            onRemove: { Task { await vm.removeJob(id: job.id) } },
            onUpdatePrompt: { prompt in Task { await vm.updatePrompt(id: job.id, newPrompt: prompt) } },
            onRename: { name in Task { await vm.renameJob(id: job.id, newName: name) } },
            siblingJobs: vm.jobs,
            supportsRemoveAndEdit: vm.supportsRemoveAndEdit
        )
    }

    /// Prefer the fetched ledger (real durations) when present; otherwise fall
    /// back to the passively-observed store records so a card is never empty
    /// before its history request returns.
    private func records(for jobID: String) -> [CronRunRecord] {
        if let ledger = ledgers[jobID], !ledger.isEmpty {
            return ledger.sorted { $0.firedAt < $1.firedAt }
        }
        return store.records(for: jobID)
    }

    private func toggle(_ node: CronCategoryNode) {
        if expandedCategories.contains(node.id) {
            expandedCategories.remove(node.id)
        } else {
            expandedCategories.insert(node.id)
        }
    }

    private func toggle(_ job: CronJob) {
        let wasExpanded = expandedJobID == job.id
        withAnimation(.easeInOut(duration: 0.18)) {
            expandedJobID = wasExpanded ? nil : job.id
        }
        guard !wasExpanded else { return }
        // Expanding: lazily fetch the full prompt and the execution ledger.
        Task { await vm.loadFullPrompt(id: job.id) }
        Task {
            let runs = await vm.loadHistory(id: job.id)
            if !runs.isEmpty { ledgers[job.id] = runs }
        }
    }
}
