import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CronGraphRevisionStore")

// MARK: - CronGraphRevisionStore

/// The observed revision log for the dataflow graph: every commitment this app
/// has seen, in the order it saw them.
///
/// **This is an observation log, not a changelog.** It records when Portal
/// noticed a new commitment, which is strictly weaker than when someone made a
/// change — see `CronGraphRevision`. Every surface that shows these entries has
/// to say so; a log that implies authorship it doesn't have is worse than no log,
/// because it will be believed.
///
/// Local and durable on purpose. The gateway has no configuration history to ask
/// for (`cron.manage history` is *run* history), so the only place a "what
/// changed and when" record can accumulate today is here, from the poll the graph
/// view already runs. That also means the log is per-machine and starts at
/// whenever this app first looked, which #384 layer 3 is what finally fixes.
@MainActor
internal final class CronGraphRevisionStore: ObservableObject {

    /// Shared because both the inline graph card and the full-screen graph build
    /// their own `CronGraphViewModel`. Two stores would mean two half-logs racing
    /// each other onto the same file, with whichever saved last winning.
    internal static let shared = CronGraphRevisionStore()

    /// Oldest first — the order they were observed in, so `last` is current and
    /// walking backwards walks history.
    @Published internal private(set) var revisions: [CronGraphRevision] = []

    /// Each entry carries a whole graph snapshot, so the cap is about disk rather
    /// than a display limit: a few hundred small graphs is well under a megabyte,
    /// and a dataflow that changes 200 times has a tail nobody is reading.
    private let maxRevisions = 200

    private var saveTask: Task<Void, Never>?

    /// Set by the testing initializer: no reads *and* no writes. Skipping only the
    /// load would leave a test appending revisions that eventually land in the
    /// real file — an in-memory store has to be in-memory in both directions.
    private let isEphemeral: Bool

    private let fileManager = FileManager.default
    private var storageDir: URL = {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/portal")
        }
        return appSupport.appendingPathComponent("portal", isDirectory: true)
    }()
    private var storeFile: URL { storageDir.appendingPathComponent("cron-graph-revisions.json") }

    private init() {
        isEphemeral = false
        load()
    }

    /// Test seam: an in-memory store that neither reads nor writes the shared
    /// file, so a test can exercise the log without inheriting this machine's
    /// history or scribbling on it.
    internal init(testing: Bool) {
        isEphemeral = testing
        guard !testing else { return }
        load()
    }

    // MARK: - Reading

    /// The current revision, or nil before the graph has ever been fetched.
    internal var latest: CronGraphRevision? { revisions.last }

    /// When this app first saw *any* revision — the start of what the log can
    /// speak to, and the honest bound on any claim it makes.
    internal var firstObservedAt: Date? { revisions.first?.observedAt }

    /// Newest first, for a list that reads top-down like a history.
    internal var newestFirst: [CronGraphRevision] { revisions.reversed() }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    /// One line describing what this log actually holds, for whatever surface
    /// shows the commitment.
    ///
    /// It spends its last clause on the caveat because the count alone reads as a
    /// claim it can't support: "12 revisions since last Tuesday" sounds like the
    /// dataflow changed twelve times, when what happened is that this app noticed
    /// twelve distinct commitments while polling every 10 seconds. A change made
    /// and undone between two polls is not in here, and one made while the app was
    /// closed is stamped with whenever it next looked.
    internal func observationSummary(now: Date = Date()) -> String {
        guard let first = firstObservedAt else {
            return "No revisions on record yet — this log begins the first time Portal reads the graph."
        }
        let noun = revisions.count == 1 ? "revision" : "revisions"
        let since = Self.relativeFormatter.localizedString(for: first, relativeTo: now)
        return "\(revisions.count) \(noun) observed since \(since). "
            + "Times are when Portal noticed a change, not when it was made."
    }

    /// The revision immediately before `revision`, or nil at the oldest entry on
    /// record. By position, not by `parentDigest`: after a revert the same digest
    /// appears twice, so following the digest could jump the log backwards to the
    /// wrong occurrence.
    internal func parent(of revision: CronGraphRevision) -> CronGraphRevision? {
        guard let index = revisions.firstIndex(where: { $0.id == revision.id }), index > 0 else {
            return nil
        }
        return revisions[index - 1]
    }

    /// What changed to produce `revision`, or nil when the log can't say.
    ///
    /// The two parentless cases are different stories and only one of them is nil.
    /// A revision with no `parentDigest` at all is the first thing this app ever
    /// saw, and diffing it against the empty graph is the truth: everything in it
    /// *was* news to the log. A revision whose `parentDigest` names an entry that
    /// has since been trimmed away is not — diffing that against empty would
    /// report a whole steady-state graph as freshly built, a change list nobody
    /// made. It gets nil so the surface can say the predecessor is gone instead of
    /// inventing one.
    internal func diff(for revision: CronGraphRevision) -> CronGraphDiff? {
        if let parent = parent(of: revision) {
            return CronGraphDiff.between(parent.graph, revision.graph)
        }
        guard revision.parentDigest == nil else { return nil }
        return CronGraphDiff.between(.empty, revision.graph)
    }

    // MARK: - Recording

    /// Record an observation of `graph`, appending a revision only if the
    /// commitment differs from the last one on record. Returns the new revision,
    /// or nil when nothing changed.
    ///
    /// Callers must only pass a graph that was actually fetched. A view model
    /// starts life holding `CronGraph.empty` and that state is not an
    /// observation of anything — but "someone deleted every job" *is* a real
    /// change to record, so this method can't tell the two apart by looking. It
    /// trusts the caller instead of guarding on emptiness, which would silence
    /// the real event to suppress the fake one.
    @discardableResult
    internal func observe(_ graph: CronGraph, at observedAt: Date = Date()) -> CronGraphRevision? {
        // Strip runtime state before both hashing and storing, so the stored
        // snapshot is exactly what its own digest commits to.
        let configuration = CronGraphDigest.configuration(of: graph)
        let digest = CronGraphDigest.over(configuration)
        guard digest.hex != revisions.last?.digest else { return nil }

        let revision = CronGraphRevision(
            digest: digest,
            parentDigest: revisions.last?.digest,
            observedAt: observedAt,
            graph: configuration
        )
        revisions.append(revision)
        trim()
        deferSave()
        return revision
    }

    private func trim() {
        guard revisions.count > maxRevisions else { return }
        // Drops the oldest, which leaves the new oldest entry's `parentDigest`
        // pointing at a revision that is no longer here. That dangle is the
        // truth — the chain is truncated, not broken — so it stays as-is rather
        // than being rewritten to nil, which would claim the graph began there.
        revisions.removeFirst(revisions.count - maxRevisions)
    }

    // MARK: - Persistence

    /// Debounced like `CronRunHistoryStore`: the graph poll can mint a revision
    /// at any tick, and a burst of edits shouldn't mean a write per edit.
    private func deferSave() {
        guard !isEphemeral, saveTask == nil else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            performSave()
            saveTask = nil
        }
    }

    private func performSave() {
        let revisions = self.revisions
        let dir = storageDir
        let file = storeFile
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(revisions)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("cron-graph-revisions save failed: \(error.localizedDescription)")
            }
        }
    }

    private func load() {
        guard fileManager.fileExists(atPath: storeFile.path) else { return }
        do {
            let data = try Data(contentsOf: storeFile)
            revisions = try JSONDecoder().decode([CronGraphRevision].self, from: data)
        } catch {
            // A log that fails to decode starts over rather than blocking the
            // graph: nothing here is authoritative, and the next fetch re-seeds
            // the current revision.
            log.error("cron-graph-revisions load failed: \(error.localizedDescription)")
        }
    }
}
