import CryptoKit
import Foundation

// MARK: - CronGraphDigest

/// A content address for the dataflow graph *as configured* — the commitment on
/// a graph revision.
///
/// `cron.graph` only ever answers "what is the wiring right now", so the graph
/// has no identity you can compare across time or quote in a bug report. A
/// digest gives it one: two reads of the graph are the same revision exactly
/// when their digests match, and a changed digest is the signal that something
/// about the dataflow was rewired.
///
/// The whole design lives in which fields the canonical form covers — see
/// `configurationForm(_:)` and `layoutForm(_:)`.
internal struct CronGraphDigest: Equatable, Hashable {

    /// Lowercase hex SHA-256 over the canonical form — 64 characters.
    internal let hex: String

    /// The display form: the first 12 hex characters, where a git short hash
    /// settles on a large repo. A graph's revisions number in the hundreds, so
    /// 48 bits is far past the point where two of them collide, and it fits in
    /// a chip.
    internal var short: String { String(hex.prefix(12)) }

    /// The commitment for the empty graph. A real value rather than a nil-ish
    /// sentinel, so "no graph loaded" and "graph loaded and empty" agree — both
    /// genuinely are the same configuration.
    internal static let emptyGraph = CronGraphDigest.over(.empty)

    /// Hash the graph's configuration.
    internal static func over(_ graph: CronGraph) -> CronGraphDigest {
        let canonical = configurationForm(graph).joined()
        let bytes = SHA256.hash(data: Data(canonical.utf8))
        return CronGraphDigest(hex: bytes.map { String(format: "%02x", $0) }.joined())
    }
}

// MARK: - Canonical forms

extension CronGraphDigest {

    /// The form the commitment is taken over: the dataflow **as configured**.
    ///
    /// A job's schedule, whether it's enabled, whether it burns a model, where
    /// it delivers, and a service's description are all part of what the
    /// dataflow *is* — editing any of them is a change someone made and should
    /// be able to see later. Every edge is in for the same reason: an edge
    /// appearing is a job reading something new.
    ///
    /// `lastStatus` and `health` are deliberately **out**, along with anything
    /// else that moves on its own. The graph is re-fetched every 10 seconds for
    /// service health (`CronGraphViewModel.refreshRuntimeState`), and a
    /// commitment that included liveness would mint a fresh revision on that
    /// timer forever — a history of the poll loop rather than of anyone's
    /// changes. A container restarting is not a change to the dataflow, and
    /// `health.latencyMilliseconds` alone would guarantee a new digest per poll.
    /// `configuration(of:)` is the same exclusion expressed as a value.
    ///
    /// Rows are sorted, so the gateway's ordering can't shift the digest.
    internal static func configurationForm(_ graph: CronGraph) -> [String] {
        let nodes = graph.nodes.map { node in
            row("n", [
                field(node.id), field(node.kind), field(node.type), field(node.label),
                field(node.description), field(node.schedule), field(node.enabled),
                field(node.usesLLM), field(node.deliver),
            ])
        }
        return (nodes + edgeRows(graph)).sorted()
    }

    /// The form that decides whether a refresh has to re-run the force layout:
    /// only what places a node or draws an edge.
    ///
    /// A strict subset of `configurationForm(_:)`, and the two are kept in one
    /// file precisely because the difference between them is the point. A
    /// schedule edit *is* a new revision but must **not** scramble a settled
    /// layout — nothing about it moves a node. Folding these two questions into
    /// one signature forces a wrong answer to one of them.
    internal static func layoutForm(_ graph: CronGraph) -> [String] {
        let nodes = graph.nodes.map { node in
            row("n", [field(node.id), field(node.kind), field(node.type), field(node.label)])
        }
        return (nodes + edgeRows(graph)).sorted()
    }

    /// The graph with every runtime field cleared — the configuration the digest
    /// actually commits to, as a value you can store.
    ///
    /// A revision snapshot has to satisfy `over(revision.graph) == revision.digest`
    /// forever, and a stored graph that still carried `lastStatus` / `health`
    /// would break that the moment those fields drift, leaving the log holding
    /// content its own commitment disowns. Stripping at write time also keeps
    /// liveness out of a diff between two revisions, where "latency 41ms → 43ms"
    /// is noise dressed as a change.
    internal static func configuration(of graph: CronGraph) -> CronGraph {
        CronGraph(
            nodes: graph.nodes.map { node in
                CronGraphNode(
                    id: node.id, kind: node.kind, type: node.type, label: node.label,
                    description: node.description, schedule: node.schedule,
                    enabled: node.enabled, usesLLM: node.usesLLM,
                    lastStatus: nil, deliver: node.deliver, health: nil
                )
            },
            edges: graph.edges
        )
    }

    private static func edgeRows(_ graph: CronGraph) -> [String] {
        graph.edges.map { row("e", [field($0.source), field($0.target), field($0.type)]) }
    }

    // MARK: - Encoding

    /// One canonical row: a tag plus its already-encoded fields.
    private static func row(_ tag: String, _ fields: [String]) -> String {
        field(tag) + fields.joined()
    }

    /// Length-prefixed so no field value can be mistaken for a field boundary.
    ///
    /// Node ids are `scheme:value` and job labels are `folder/name`, so any
    /// plain separator already appears inside the values it would separate:
    /// joining on `:` lets `wiki:a` + `artifact` and `wiki` + `a:artifact`
    /// produce the same string. That's a collision between two different graphs,
    /// which for a *content address* is the one failure that matters, however
    /// unlikely the pair. Encoding the byte count removes the ambiguity instead
    /// of betting against it.
    private static func field(_ value: String) -> String {
        "\(value.utf8.count):\(value)"
    }

    /// nil is distinct from empty: a job with no schedule and a job whose
    /// schedule was cleared to `""` are different configurations, and a
    /// `?? ""` collapse would hide the edit between them.
    private static func field(_ value: String?) -> String {
        guard let value else { return "-" }
        return "+" + field(value)
    }

    private static func field(_ value: Bool) -> String {
        value ? "1" : "0"
    }
}
