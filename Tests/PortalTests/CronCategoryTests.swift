import Testing
import Foundation
@testable import Portal

/// Coverage for `CronCategory` — the name-path parsing and tree rollup that back
/// the Cron page's grouped mode. Pure logic, no gateway or view dependencies.
@Suite("Cron Category Paths")
internal struct CronCategoryTests {

    /// Minimal job; only `name` matters to categorization.
    private func job(_ name: String, lastRun: Date? = nil) -> CronJob {
        CronJob(
            id: name,
            name: name,
            schedule: "every 60m",
            nextRunAt: nil,
            lastRunAt: lastRun,
            lastStatus: "ok",
            enabled: true,
            state: "scheduled",
            deliver: "local",
            promptPreview: nil,
            prompt: nil,
            lastError: nil
        )
    }

    // MARK: - Splitting

    @Test("a multi-level name splits into path and leaf title")
    internal func splitsNestedName() {
        let (path, title) = CronCategory.split(name: "life/training/morning-run")
        #expect(path == ["life", "training"])
        #expect(title == "morning-run")
    }

    @Test("a name with no separator is ungrouped and keeps its whole name")
    internal func splitsBareName() {
        let (path, title) = CronCategory.split(name: "db-backup")
        #expect(path.isEmpty)
        #expect(title == "db-backup")
    }

    @Test("arbitrary depth is supported")
    internal func splitsDeepName() {
        let (path, title) = CronCategory.split(name: "life/training/cardio/intervals/sprint")
        #expect(path == ["life", "training", "cardio", "intervals"])
        #expect(title == "sprint")
    }

    @Test("empty components collapse so concatenated fragments don't add levels")
    internal func normalizesEmptyComponents() {
        let (path, title) = CronCategory.split(name: "life//training/")
        #expect(path == ["life"])
        #expect(title == "training")
    }

    @Test("whitespace around components is trimmed")
    internal func trimsComponents() {
        let (path, title) = CronCategory.split(name: "life / training / run")
        #expect(path == ["life", "training"])
        #expect(title == "run")
    }

    @Test("a name of only separators degrades to the original string")
    internal func handlesSeparatorOnlyName() {
        let (path, title) = CronCategory.split(name: "///")
        #expect(path.isEmpty)
        #expect(title == "///")
    }

    @Test("title and isUngrouped read through to a job")
    internal func readsJobHelpers() {
        #expect(CronCategory.title(for: job("life/training/run")) == "run")
        #expect(CronCategory.path(for: job("life/training/run")) == ["life", "training"])
        #expect(CronCategory.isUngrouped(job("db-backup")))
        #expect(!CronCategory.isUngrouped(job("infra/db-backup")))
    }

    // MARK: - Normalizing a typed name (rename == recategorize)

    /// The rename field is a path editor, so what the user types is normalized
    /// before it reaches the gateway. `split(name:)` already collapses noise on
    /// the way in; `normalize(name:)` must agree on the way out, or a job could
    /// be stored as `life/training/` and read back as `life/training`.
    @Test("normalize round-trips a clean path unchanged")
    internal func normalizeKeepsCleanPath() {
        #expect(CronCategory.normalize(name: "life/training/run") == "life/training/run")
        #expect(CronCategory.normalize(name: "db-backup") == "db-backup")
    }

    @Test("normalize collapses the same noise split() ignores")
    internal func normalizeCollapsesNoise() {
        #expect(CronCategory.normalize(name: "life//training/") == "life/training")
        #expect(CronCategory.normalize(name: " life / training / run ") == "life/training/run")
        #expect(CronCategory.normalize(name: "/leading") == "leading")
    }

    /// Unlike `split(name:)`, which preserves a separator-only name for display,
    /// normalize refuses to *write* one — the gateway would then hold a job with
    /// no usable title.
    @Test("normalize rejects names with nothing usable left")
    internal func normalizeRejectsEmpty() {
        #expect(CronCategory.normalize(name: "") == nil)
        #expect(CronCategory.normalize(name: "   ") == nil)
        #expect(CronCategory.normalize(name: "///") == nil)
        #expect(CronCategory.normalize(name: " / / ") == nil)
    }

    /// Guards the Save/Move button: a rename that normalizes back to the current
    /// name is a wasted round trip plus a list refresh, and an empty one is a
    /// destructive mistake.
    @Test("isRenameable rejects no-ops and unusable names")
    internal func isRenameableGatesTheButton() {
        #expect(CronCategory.isRenameable("infra/db-backup", from: "db-backup"))
        // Moving out of a category is a legitimate rename too.
        #expect(CronCategory.isRenameable("db-backup", from: "infra/db-backup"))
        // Same destination after normalizing — nothing to do.
        #expect(!CronCategory.isRenameable("db-backup", from: "db-backup"))
        #expect(!CronCategory.isRenameable(" db-backup ", from: "db-backup"))
        #expect(!CronCategory.isRenameable("infra/db-backup/", from: "infra/db-backup"))
        #expect(!CronCategory.isRenameable("", from: "db-backup"))
        #expect(!CronCategory.isRenameable("///", from: "db-backup"))
    }

    /// The whole point of the feature: the normalized name regroups without any
    /// migration, because the category is read out of the name itself.
    @Test("a normalized rename lands the job in the intended category")
    internal func renameRefilesTheJob() throws {
        let renamed = try #require(CronCategory.normalize(name: " infra / db-backup "))
        let grouping = CronCategory.group([job(renamed)])

        #expect(grouping.ungrouped.isEmpty)
        let infra = try #require(grouping.roots.first)
        #expect(infra.name == "infra")
        #expect(infra.jobs.map { CronCategory.title(for: $0) } == ["db-backup"])
    }

    // MARK: - The rename RPC shape

    /// The bug this guards is silent in both directions: `cron.manage` uses
    /// `name` as the job *identifier*, so the new name must be `job_name`.
    /// Swapping them either addresses a nonexistent job or renames the job to
    /// its own id — the gateway reports success either way.
    @MainActor
    @Test("rename sends the id as name and the new name as job_name")
    internal func renameParamsUseJobNameForTheNewName() throws {
        let params = try #require(
            CronListViewModel.renameParams(id: "job-7", newName: "infra/db-backup"))

        #expect(params["action"] == AnyCodable("update"))
        #expect(params["name"] == AnyCodable("job-7"), "`name` is the job identifier")
        #expect(params["job_name"] == AnyCodable("infra/db-backup"), "the NEW name rides on job_name")
        // Nothing else may ride along: `update` overwrites the fields it receives.
        #expect(params.keys.sorted() == ["action", "job_name", "name"])
    }

    @MainActor
    @Test("rename normalizes the path before it reaches the wire")
    internal func renameParamsNormalize() throws {
        let params = try #require(
            CronListViewModel.renameParams(id: "job-7", newName: " infra / db-backup / "))
        #expect(params["job_name"] == AnyCodable("infra/db-backup"))
    }

    @MainActor
    @Test("an unusable new name yields no params, so nothing is sent")
    internal func renameParamsRefuseEmptyNames() {
        #expect(CronListViewModel.renameParams(id: "job-7", newName: "") == nil)
        #expect(CronListViewModel.renameParams(id: "job-7", newName: "   ") == nil)
        #expect(CronListViewModel.renameParams(id: "job-7", newName: "///") == nil)
    }

    // MARK: - Reporting a failed move

    /// `cron.manage` only grew its `update` action recently (hermes-agent PR #41),
    /// so a harness on an older build answers `unknown cron action: update`. Echoed
    /// raw that reads like a Portal bug; it's version skew, and the message has to
    /// say so or the user debugs the wrong thing.
    @MainActor
    @Test("an old gateway's unknown-action error becomes update-your-harness advice")
    internal func mapsUnknownActionToVersionSkew() {
        struct WireError: Error { let message = "unknown cron action: update" }
        let message = CronListViewModel.renameFailureMessage(for: WireError())

        #expect(message.lowercased().contains("too old"))
        #expect(message.lowercased().contains("update the harness"))
        // The raw wire text must not leak — that's what made it unreadable.
        #expect(!message.contains("4016"))
    }

    @MainActor
    @Test("any other failure still reports something concrete")
    internal func mapsOtherErrorsToTheirDescription() {
        struct Timeout: LocalizedError {
            var errorDescription: String? { "The request timed out." }
        }
        let message = CronListViewModel.renameFailureMessage(for: Timeout())

        #expect(message.contains("The request timed out."))
        #expect(!message.lowercased().contains("too old"))
    }

    // MARK: - Grouping

    @Test("jobs group under their root category")
    internal func groupsByRoot() {
        let grouping = CronCategory.group([
            job("life/training/run"),
            job("life/finance/budget"),
            job("work/standup"),
        ])

        #expect(grouping.roots.map(\.name) == ["life", "work"])
        #expect(grouping.ungrouped.isEmpty)
    }

    @Test("ungrouped jobs are kept separate, not guessed into a category")
    internal func keepsUngroupedSeparate() {
        let grouping = CronCategory.group([
            job("life/training/run"),
            job("db-backup"),
            job("news-digest"),
        ])

        #expect(grouping.roots.map(\.name) == ["life"])
        #expect(grouping.ungrouped.map(\.name) == ["db-backup", "news-digest"])
    }

    @Test("totalCount rolls up the whole subtree, not just direct jobs")
    internal func rollsUpCounts() throws {
        let grouping = CronCategory.group([
            job("life/training/run"),
            job("life/training/lifting"),
            job("life/finance/budget"),
            job("life/checkin"),
        ])

        let life = try #require(grouping.roots.first { $0.name == "life" })
        // 3 nested + 1 sitting directly at `life`.
        #expect(life.totalCount == 4)
        #expect(life.jobs.map(\.name) == ["life/checkin"])

        let training = try #require(life.children.first { $0.name == "training" })
        #expect(training.totalCount == 2)
    }

    @Test("intermediate levels exist even when they hold no jobs of their own")
    internal func synthesizesIntermediateLevels() throws {
        let grouping = CronCategory.group([job("a/b/c/deep")])

        let a = try #require(grouping.roots.first)
        #expect(a.name == "a")
        #expect(a.jobs.isEmpty)
        #expect(a.totalCount == 1)

        let b = try #require(a.children.first)
        #expect(b.name == "b")
        let c = try #require(b.children.first)
        #expect(c.name == "c")
        #expect(c.jobs.map(\.name) == ["a/b/c/deep"])
    }

    @Test("category levels sort alphabetically, case-insensitively")
    internal func sortsCategories() {
        let grouping = CronCategory.group([
            job("Zebra/x"),
            job("alpha/y"),
            job("Mango/z"),
        ])
        #expect(grouping.roots.map(\.name) == ["alpha", "Mango", "Zebra"])
    }

    @Test("job order within a level preserves the incoming sort")
    internal func preservesJobOrderWithinLevel() throws {
        // Callers pass an already-sorted list; grouping must not re-sort jobs.
        let grouping = CronCategory.group([
            job("life/zzz-last"),
            job("life/aaa-first"),
        ])
        let life = try #require(grouping.roots.first)
        #expect(life.jobs.map { CronCategory.title(for: $0) } == ["zzz-last", "aaa-first"])
    }

    @Test("an empty job list produces an empty grouping")
    internal func handlesEmptyInput() {
        let grouping = CronCategory.group([])
        #expect(grouping.isEmpty)
        #expect(grouping.hasNoCategories)
    }

    @Test("all-ungrouped input reports no categories so the view can stay flat")
    internal func reportsNoCategories() {
        let grouping = CronCategory.group([job("one"), job("two")])
        #expect(grouping.hasNoCategories)
        #expect(!grouping.isEmpty)
        #expect(grouping.ungrouped.count == 2)
    }

    @Test("node id is the joined path, unique per level")
    internal func nodeIDIsPath() throws {
        let grouping = CronCategory.group([job("life/training/run")])
        let life = try #require(grouping.roots.first)
        #expect(life.id == "life")
        let training = try #require(life.children.first)
        #expect(training.id == "life/training")
    }

    @Test("hasChildren is true for a leaf category holding only jobs")
    internal func leafWithJobsHasChildren() throws {
        let grouping = CronCategory.group([job("life/run")])
        let life = try #require(grouping.roots.first)
        #expect(life.children.isEmpty)
        #expect(life.hasChildren)
    }

    // MARK: - Row flattening

    @Test("a collapsed tree renders only root headers")
    internal func collapsedRowsAreHeadersOnly() {
        let grouping = CronCategory.group([
            job("life/training/run"),
            job("work/standup"),
        ])
        let rows = grouping.rows(expanded: [])

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { if case .category = $0 { return true } else { return false } })
    }

    @Test("expanding a root reveals its children but not its grandchildren")
    internal func expansionIsOneLevelDeep() {
        let grouping = CronCategory.group([job("life/training/run")])
        let rows = grouping.rows(expanded: ["life"])

        // life (root) + training (child header). `run` stays hidden under the
        // still-collapsed `training`.
        #expect(rows.count == 2)
        #expect(rows.map(\.id) == ["cat:life", "cat:life/training"])
    }

    @Test("fully expanding reveals jobs at their nesting depth")
    internal func fullExpansionRevealsJobs() throws {
        let grouping = CronCategory.group([job("life/training/run")])
        let rows = grouping.rows(expanded: ["life", "life/training"])

        #expect(rows.map(\.id) == ["cat:life", "cat:life/training", "job:life/training/run"])

        let last = try #require(rows.last)
        guard case .job(_, let depth) = last else {
            Issue.record("expected a job row")
            return
        }
        // life=0, training=1, so the job indents at 2.
        #expect(depth == 2)
    }

    @Test("jobs at a level precede that level's nested categories")
    internal func jobsPrecedeSubcategories() {
        let grouping = CronCategory.group([
            job("life/training/run"),
            job("life/checkin"),
        ])
        let rows = grouping.rows(expanded: ["life", "life/training"])

        #expect(rows.map(\.id) == [
            "cat:life",
            "job:life/checkin",
            "cat:life/training",
            "job:life/training/run",
        ])
    }

    @Test("ungrouped jobs are not part of the tree rows")
    internal func ungroupedExcludedFromRows() {
        let grouping = CronCategory.group([job("life/run"), job("db-backup")])
        let rows = grouping.rows(expanded: ["life"])

        #expect(!rows.contains { $0.id == "job:db-backup" })
        #expect(grouping.ungrouped.map(\.name) == ["db-backup"])
    }

    @Test("row headers carry their expansion state")
    internal func headersCarryExpansionState() throws {
        let grouping = CronCategory.group([job("life/run"), job("work/x")])
        let rows = grouping.rows(expanded: ["life"])

        let life = try #require(rows.first { $0.id == "cat:life" })
        guard case .category(_, _, let lifeOpen) = life else {
            Issue.record("expected a category row")
            return
        }
        #expect(lifeOpen)

        let work = try #require(rows.first { $0.id == "cat:work" })
        guard case .category(_, _, let workOpen) = work else {
            Issue.record("expected a category row")
            return
        }
        #expect(!workOpen)
    }

    // MARK: - What a row is called

    /// The reported bug: under a folder named `autoresearch`, the job inside it
    /// still read `autoresearch/ingest`, so the folder name was printed twice on
    /// every line and the tree looked like it hadn't grouped anything.
    @Test("a job under its category headers reads as just the leaf")
    internal func groupedRowShowsLeafOnly() {
        let ingest = job("autoresearch/ingest")
        #expect(CronCategory.displayName(for: ingest, showingPath: false) == "ingest")
    }

    @Test("a job standing alone keeps its whole path")
    internal func flatRowShowsFullPath() {
        // Flat mode and the Ungrouped section have no headers above them, so the
        // name is the only place the category is visible — stripping it there
        // would lose the information rather than de-duplicate it.
        let ingest = job("autoresearch/ingest")
        #expect(CronCategory.displayName(for: ingest, showingPath: true) == "autoresearch/ingest")
    }

    @Test("only the last path component survives at any depth")
    internal func deepGroupedRowShowsLeafOnly() {
        // Nested headers spell out every level, so a deep job strips all of them,
        // not just the first.
        let sprint = job("life/training/cardio/sprint")
        #expect(CronCategory.displayName(for: sprint, showingPath: false) == "sprint")
    }

    @Test("an uncategorized job reads the same either way")
    internal func ungroupedNameIsStable() {
        // Nothing to strip, so the flag can't accidentally blank the row — this
        // is what a card in the Ungrouped section renders.
        let backup = job("db-backup")
        #expect(CronCategory.displayName(for: backup, showingPath: false) == "db-backup")
        #expect(CronCategory.displayName(for: backup, showingPath: true) == "db-backup")
    }

    @Test("a malformed name never renders as empty")
    internal func separatorOnlyNameStillRenders() {
        // `split` preserves a separators-only name as its own title, so a row
        // shows something identifiable instead of a blank line.
        let odd = job("///")
        #expect(CronCategory.displayName(for: odd, showingPath: false) == "///")
    }

    @Test("the leaf shown matches the leaf the tree filed the job under")
    internal func displayNameAgreesWithGrouping() throws {
        // The two must not drift: the header says `autoresearch`, so whatever the
        // row shows has to be exactly the remainder of the name.
        let grouping = CronCategory.group([job("autoresearch/ingest")])
        let root = try #require(grouping.roots.first)
        #expect(root.name == "autoresearch")

        let filed = try #require(root.jobs.first)
        #expect(CronCategory.displayName(for: filed, showingPath: false) == "ingest")
        #expect(root.name + "/" + CronCategory.displayName(for: filed, showingPath: false)
                == filed.name)
    }

    // MARK: - Moving without retyping the name

    @Test("moving an ungrouped job into a category keeps its leaf name")
    internal func moveKeepsLeafName() {
        #expect(CronCategory.moved(name: "morning-run", to: ["life", "training"])
                == "life/training/morning-run")
    }

    @Test("moving a categorized job replaces only its path")
    internal func moveReplacesPath() {
        #expect(CronCategory.moved(name: "life/training/run", to: ["work"]) == "work/run")
        #expect(CronCategory.moved(name: "a/b/c/deep", to: ["x", "y"]) == "x/y/deep")
    }

    @Test("moving to the root ungroups the job without renaming it")
    internal func moveToRootUngroups() {
        #expect(CronCategory.moved(name: "life/training/run", to: []) == "run")
    }

    @Test("a move never mangles the leaf, whatever noise the destination carries")
    internal func moveNormalizesDestination() {
        // The picker can hand over typed input, so the same noise `split` ignores
        // must not create phantom levels here either.
        #expect(CronCategory.moved(name: "run", to: ["", " life ", "training"])
                == "life/training/run")
    }

    @Test("a name with no usable leaf refuses to move")
    internal func moveRefusesEmptyLeaf() {
        #expect(CronCategory.moved(name: "///", to: ["life"]) == nil)
        #expect(CronCategory.moved(name: "   ", to: ["life"]) == nil)
    }

    @Test("a job already in the destination produces an unchanged name")
    internal func moveToSamePlaceIsIdentity() {
        // The editor keys its disabled-Move state on this equality, so it has to
        // hold exactly rather than merely normalize to something similar.
        #expect(CronCategory.moved(name: "life/run", to: ["life"]) == "life/run")
    }

    // MARK: - Destination enumeration

    @Test("existing categories are offered including intermediate levels")
    internal func allPathsIncludesIntermediates() {
        let paths = CronCategory.allPaths(in: [
            job("life/training/run"),
            job("work/x"),
            job("db-backup"),
        ])
        // `life` is offered even though no job sits directly at it — moving a job
        // up one level is as reasonable as moving it down.
        #expect(paths.contains(["life"]))
        #expect(paths.contains(["life", "training"]))
        #expect(paths.contains(["work"]))
        // Ungrouped jobs contribute no destination.
        #expect(paths.count == 3)
    }

    /// Same-depth paths that share a prefix component must order by their
    /// differing component. This exercises the `where l != r` filter inside the
    /// sort comparator: the matching prefix element is skipped before the loop
    /// finds the component that actually decides the order.
    @Test("same-depth paths with a shared prefix sort by the differing component")
    internal func allPathsOrdersSharedPrefixByDifferingComponent() {
        let paths = CronCategory.allPaths(in: [
            job("life/beta/run"),
            job("life/alpha/swim"),
        ])
        #expect(paths == [["life"], ["life", "alpha"], ["life", "beta"]])
    }

    @Test("destinations are ordered shallowest-first then alphabetically")
    internal func allPathsOrdering() {
        // Note the leaf is never a category: `life/a/run` contributes `life` and
        // `life/a`, not `life/a/run`.
        let paths = CronCategory.allPaths(in: [
            job("work/b/deep"),
            job("life/a/run"),
        ])
        #expect(paths == [["life"], ["work"], ["life", "a"], ["work", "b"]])
    }

    @Test("a list with no categories offers no destinations")
    internal func allPathsEmptyWhenUngrouped() {
        #expect(CronCategory.allPaths(in: [job("a"), job("b")]).isEmpty)
    }

    @Test("a path renders as a breadcrumb, and the root as Ungrouped")
    internal func displayPathRendering() {
        #expect(CronCategory.displayPath(["life", "training"]) == "life › training")
        #expect(CronCategory.displayPath([]) == "Ungrouped")
    }

    // MARK: - Separator footgun

    /// The convention reserves `/`, and there is no escape hatch, so a name that
    /// reads as prose gets silently filed into a category. These pin the heuristic
    /// that decides when to warn.
    @Test("a space-bearing path component warns, naming where it would land")
    internal func warnsOnProseSeparator() throws {
        let warning = try #require(CronCategory.separatorWarning(for: "A/B testing digest"))
        #expect(warning.contains("A"))
        // The advice has to be actionable, not just a statement that it happened.
        #expect(warning.lowercased().contains("remove the slash"))
    }

    @Test("a deliberate category path never warns")
    internal func staysQuietForRealPaths() {
        #expect(CronCategory.separatorWarning(for: "life/training/morning-run") == nil)
        #expect(CronCategory.separatorWarning(for: "infra/db-backup") == nil)
        #expect(CronCategory.separatorWarning(for: "a/b/c/deep") == nil)
    }

    /// A space in the leaf under a *normal* category is just a job title — warning
    /// there would fire on most legitimate names and train the user to ignore it.
    @Test("a space in the leaf under a real category is not a warning")
    internal func ignoresSpacesInTheLeaf() {
        #expect(CronCategory.separatorWarning(for: "life/morning run") == nil)
        #expect(CronCategory.separatorWarning(for: "work/weekly status report") == nil)
    }

    /// The motivating case is an abbreviation, where the "category" is one or two
    /// characters and the leaf is prose: `A/B`, `I/O`, `24/7`. A real category that
    /// short is rare; this pairing is almost always a slash meant literally.
    @Test("a prose leaf under a very short category reads as an abbreviation")
    internal func warnsOnAbbreviations() {
        #expect(CronCategory.separatorWarning(for: "A/B testing digest") != nil)
        #expect(CronCategory.separatorWarning(for: "I/O latency check") != nil)
        #expect(CronCategory.separatorWarning(for: "24/7 uptime probe") != nil)
        // …but a short category with a slug leaf is a legitimate path.
        #expect(CronCategory.separatorWarning(for: "ci/nightly-build") == nil)
    }

    @Test("an uncategorized or unusable name has nothing to warn about")
    internal func noWarningWithoutAPath() {
        #expect(CronCategory.separatorWarning(for: "A B testing digest") == nil)
        #expect(CronCategory.separatorWarning(for: "db-backup") == nil)
        #expect(CronCategory.separatorWarning(for: "") == nil)
        #expect(CronCategory.separatorWarning(for: "///") == nil)
    }

    /// Noise is collapsed before the check, so a trailing slash doesn't invent a
    /// path component and a doubled one doesn't hide a real warning.
    @Test("the warning check normalizes first")
    internal func warningNormalizesFirst() {
        // "life/" collapses to a bare leaf — no path, so no warning.
        #expect(CronCategory.separatorWarning(for: "life/") == nil)
        #expect(CronCategory.separatorWarning(for: "A B//testing digest") != nil)
    }
}

/// `CronFilterState` is the pure filtering layer behind the cron list. Keep its
/// user-visible combinations pinned here alongside the category grouping it
/// delegates to; no gateway or view needs to be involved.
@MainActor
@Suite("Cron Filter State")
internal struct CronFilterStateTests {
    private func job(
        _ name: String,
        enabled: Bool = true,
        state: String = "scheduled",
        lastStatus: String? = "ok",
        lastRunAt: Date? = nil,
        nextRunAt: Date? = nil,
        deliver: String = "local",
        promptPreview: String? = nil,
        prompt: String? = nil
    ) -> CronJob {
        CronJob(
            id: name,
            name: name,
            schedule: "every 60m",
            nextRunAt: nextRunAt,
            lastRunAt: lastRunAt,
            lastStatus: lastStatus,
            enabled: enabled,
            state: state,
            deliver: deliver,
            promptPreview: promptPreview,
            prompt: prompt,
            lastError: nil
        )
    }

    @Test("defaults leave jobs visible and order the most recent run first")
    internal func defaultsApplyRecentOrder() {
        let state = CronFilterState()
        let early = job("early", lastRunAt: Date(timeIntervalSince1970: 100))
        let never = job("never")
        let late = job("late", lastRunAt: Date(timeIntervalSince1970: 200))

        #expect(state.filterStatus == .all)
        #expect(state.timeWindow == .all)
        #expect(state.sortOrder == .recent)
        #expect(state.apply(to: [early, never, late]).map(\.name) == ["late", "early", "never"])
    }

    @Test("status filters distinguish active, paused, and failing jobs")
    internal func statusFiltersAndCounts() {
        let active = job("active")
        let disabled = job("disabled", enabled: false)
        let paused = job("paused", state: "paused")
        let failing = job("failing", lastStatus: "error")
        let jobs = [active, disabled, paused, failing]
        let state = CronFilterState()

        state.filterStatus = .active
        #expect(state.apply(to: jobs).map(\.name).sorted() == ["active", "failing"])
        state.filterStatus = .paused
        #expect(state.apply(to: jobs).map(\.name).sorted() == ["disabled", "paused"])
        state.filterStatus = .failing
        #expect(state.apply(to: jobs).map(\.name) == ["failing"])
        #expect(state.count(for: .all, in: jobs) == 4)
        #expect(state.count(for: .active, in: jobs) == 2)
        #expect(state.count(for: .paused, in: jobs) == 2)
        #expect(state.count(for: .failing, in: jobs) == 1)
    }

    @Test("search is trimmed, case-insensitive, and covers every visible facet")
    internal func searchCoversVisibleFacets() {
        let jobs = [
            job("Nightly Backup"),
            job("delivery", deliver: "TELEGRAM:ops"),
            job("preview", promptPreview: "Summarize incidents"),
            job("prompt", prompt: "Inspect the deploy queue"),
        ]
        let state = CronFilterState()

        for (query, expected) in [
            (" nightly ", "Nightly Backup"),
            ("telegram", "delivery"),
            ("INCIDENTS", "preview"),
            ("deploy queue", "prompt"),
            ("60M", "Nightly Backup"),
        ] {
            state.searchText = query
            #expect(state.apply(to: jobs).first?.name == expected)
        }
    }

    @Test("next-run and name sorts put missing dates last and ignore name case")
    internal func alternateSortOrders() {
        let first = job("zulu", nextRunAt: Date(timeIntervalSince1970: 100))
        let second = job("Alpha", nextRunAt: Date(timeIntervalSince1970: 200))
        let unscheduled = job("beta")
        let state = CronFilterState()

        state.sortOrder = .next
        #expect(state.apply(to: [unscheduled, second, first]).map(\.name) == ["zulu", "Alpha", "beta"])
        state.sortOrder = .name
        #expect(state.apply(to: [first, unscheduled, second]).map(\.name) == ["Alpha", "beta", "zulu"])
    }

    @Test("grouping applies the active filter and sort before building the tree")
    internal func groupingUsesFilteredOrder() throws {
        let state = CronFilterState()
        state.filterStatus = .active
        state.sortOrder = .name
        let grouping = state.grouped([
            job("life/zulu"),
            job("life/Alpha"),
            job("life/hidden", enabled: false),
        ])

        let life = try #require(grouping.roots.first)
        #expect(life.jobs.map(\.name) == ["life/Alpha", "life/zulu"])
    }

    @Test("category expansion toggles one node and can reveal an entire tree")
    internal func categoryExpansionState() throws {
        let state = CronFilterState()
        let grouping = state.grouped([
            job("life/training/run"),
            job("work/review"),
        ])
        let life = try #require(grouping.roots.first { $0.id == "life" })

        #expect(!state.isExpanded(life))
        state.toggleExpanded(life)
        #expect(state.isExpanded(life))
        state.toggleExpanded(life)
        #expect(!state.isExpanded(life))

        state.expandAll(in: grouping)
        #expect(state.expandedCategories == ["life", "life/training", "work"])
    }

    @Test("time-window presets retain their UI order and labels")
    internal func timeWindowPresetsAndLabels() {
        #expect(CronFilterState.TimeWindow.presets == [.all, .hour, .day, .week, .month])
        #expect(CronFilterState.TimeWindow.presets.map(\.label)
                == ["All time", "Last hour", "Last 24h", "Last 7d", "Last 30d"])
    }
}
