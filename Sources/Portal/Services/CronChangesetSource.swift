import Foundation

// MARK: - CronChangesetSource

/// Capability marker for backends that record a cron configuration history
/// (`cron.changesets` / `cron.changeset_diff`).
///
/// A protocol rather than a version sniff, for the reason written down in
/// `WikiChangesetSource`: a capability is a question about what a source can do,
/// and a version number is a proxy for it that goes wrong in both directions.
///
/// But conformance alone can't answer this one. There is exactly one cron
/// source — the home gateway — so a conformance check here is a compile-time
/// constant, and the real question ("does *this* gateway record history?") is
/// answered by the gateway at runtime with a method-not-found. So the capability
/// has two halves, and both are needed:
///
/// 1. **This protocol**: does the client speak the RPC at all, and against what
///    types. It's what lets a test hand over a source that *does* record
///    history, so the recorded path is exercised without a backend that has it.
/// 2. **`CronChangesetFeed.Availability`**: does the gateway answer. A
///    method-not-found means no history and Portal falls back to its own
///    observed log; anything else means the call failed and must not be
///    reported as "this gateway records nothing", because that's a claim about
///    the backend made from a network error.
@MainActor
internal protocol CronChangesetSource {

    /// Recorded configuration changes, newest first.
    ///
    /// - Parameters:
    ///   - limit: Page size.
    ///   - offset: Pagination offset.
    ///   - since: Only changes at/after this ISO 8601 instant.
    ///   - until: Only changes at/before this ISO 8601 instant.
    ///   - job: Restrict to one job's history.
    func cronChangesets(
        limit: Int,
        offset: Int,
        since: String?,
        until: String?,
        job: String?
    ) async throws -> CronChangesetsPage

    /// The graphs on either side of one recorded change.
    ///
    /// Graphs, not statements. The gateway supplies the *facts* — which
    /// revisions exist, when, by whom, and the configuration at each — and this
    /// app derives the sentences with `CronGraphDiff.between`, exactly as it does
    /// for its own observed log. Asking the backend to also produce statements
    /// would mean two dialects of "what changed" that drift apart, and the
    /// drawer would have to render both.
    func cronChangesetDiff(id: String) async throws -> CronChangesetDiff
}

// MARK: - CronChangesetDiff

/// The payload of `cron.changeset_diff`: the configuration before and after,
/// plus a text diff when job definitions are file-backed.
internal struct CronChangesetDiff: Equatable {

    /// The configuration before the change. Nil means the gateway didn't send
    /// one, which is a different thing from "there was nothing before" — see
    /// `structural(parentDigest:)`.
    internal let before: CronGraph?
    internal let after: CronGraph?

    /// A unified text diff, when the gateway has files to diff. Shown as an
    /// extra beneath the statements, never as the primary reading: a graph isn't
    /// a file, and the statements are the part that reads like an answer.
    internal let unifiedText: String?

    internal init(before: CronGraph?, after: CronGraph?, unifiedText: String? = nil) {
        self.before = before
        self.after = after
        self.unifiedText = unifiedText
    }

    /// The typed statements, or nil when this app can't honestly derive them.
    ///
    /// Same rule as `CronGraphRevisionStore.diff(for:)`, deliberately: a missing
    /// `before` is only the empty graph when the change had no parent at all. If
    /// it had one and the gateway didn't send it, diffing against empty would
    /// report a whole steady-state graph as freshly built — a change list nobody
    /// made — so it returns nil and the surface says the comparison isn't
    /// available.
    internal func structural(parentDigest: String?) -> CronGraphDiff? {
        guard let after else { return nil }
        if let before { return CronGraphDiff.between(before, after) }
        guard parentDigest == nil else { return nil }
        return CronGraphDiff.between(.empty, after)
    }
}
