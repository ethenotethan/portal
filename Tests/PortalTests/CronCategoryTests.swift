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
}
