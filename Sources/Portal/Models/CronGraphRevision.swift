import Foundation

// MARK: - CronGraphRevision

/// One observed state of the dataflow graph, as Portal saw it.
///
/// **Observed, not authored.** `observedAt` is when this app noticed a new
/// commitment, which is not when anyone made the change: the graph is polled, so
/// a change made and reverted between two polls leaves no trace here, and a
/// change made overnight is stamped with the moment the app next looked. That
/// gap is exactly what a gateway-side `cron.changesets` (#384 layer 3) closes.
/// Until then the surface has to say so rather than imply an authorship it
/// doesn't have.
///
/// The full graph is kept, not just its counts. A log of digests could only tell
/// you *that* something changed; diffing two revisions — including two old ones —
/// needs the content of both. Cron graphs are a handful of nodes, so the snapshot
/// is cheap, and it's the difference between layer 2 diffing any pair of
/// revisions and layer 2 diffing only whatever happens to still be in memory.
internal struct CronGraphRevision: Identifiable, Codable, Equatable {

    /// Per-*observation* identity, deliberately not the digest.
    ///
    /// A revert (A → B → A) makes the third observation's digest equal the
    /// first's, and both observations are real events that belong in the log.
    /// Keying identity on the digest would drop one of them or collide two rows.
    /// "Is this the same configuration as that" is `digest ==`; "is this the same
    /// entry" is `id ==`, and the two questions are not the same question.
    internal let id: UUID

    /// The commitment for this configuration — `CronGraphDigest.hex`.
    internal let digest: String

    /// The digest this one succeeded, or nil for the oldest entry on record.
    ///
    /// Nil also appears mid-log after a trim: the chain is truncated, not broken,
    /// and a reader that walks parents must stop at a nil rather than conclude
    /// the graph began there.
    internal let parentDigest: String?

    /// When Portal noticed. See the type's note: not when the change was made.
    internal let observedAt: Date

    /// The graph as it stood at this revision, kept so any two revisions can be
    /// diffed later.
    internal let graph: CronGraph

    internal var shortDigest: String { String(digest.prefix(12)) }

    /// Jobs, not nodes — the count a person means by "how big is this graph".
    internal var jobCount: Int { graph.nodes.filter { $0.kind == "cron" }.count }
    internal var nodeCount: Int { graph.nodes.count }
    internal var edgeCount: Int { graph.edges.count }

    internal init(
        id: UUID = UUID(),
        digest: CronGraphDigest,
        parentDigest: String?,
        observedAt: Date,
        graph: CronGraph
    ) {
        self.id = id
        self.digest = digest.hex
        self.parentDigest = parentDigest
        self.observedAt = observedAt
        self.graph = graph
    }
}
