import Foundation

// MARK: - Cron interflow graph

/// One node in the cron interflow dataflow graph (from the `cron.graph` RPC).
///
/// Five kinds:
/// - `cron` — a scheduled job (id = the bare hex job id; carries schedule and
///   run metadata).
/// - `source` — an external input read by ≥1 cron and written by none.
/// - `artifact` — a data ref written by ≥1 cron: the join node between a
///   producer and its consumers (a produced ref outranks a plain source).
/// - `sink` — a terminal side-effect target (telegram / pr / webhook …).
/// - `service` — a long-running process or container the harness tracks (a
///   dashboard, a Postgres, a Redis) that reads/writes the same refs a cron
///   does. Liveness is the tracked process / `docker ps` presence, and it
///   carries a required markdown `description` shown in the node detail card.
///
/// Resource and sink ids are `scheme:value` (always contain a colon); cron ids
/// are bare 12-hex, and service ids are `docker:<id>` or a process handle — the
/// id spaces never collide, so shared refs dedupe a service onto a cron's store.
internal struct CronGraphNode: Identifiable, Hashable {
    internal let id: String
    /// `cron` | `source` | `artifact` | `sink` | `service` — drives node color.
    internal let kind: String
    /// Fine-grained type: `cron` for jobs, `service` for services, else the ref
    /// scheme (`https`, `wiki`, `telegram`, …).
    internal let type: String
    internal let label: String
    /// Markdown blurb of what a `service` node is / does — required on services
    /// (the server rejects an empty one), empty for every other kind. Rendered
    /// in the node detail card so you can expand a service and read its purpose.
    internal let description: String
    // Cron-only metadata — nil / defaults for resource and sink nodes.
    internal let schedule: String?
    internal let enabled: Bool
    internal let usesLLM: Bool
    internal let lastStatus: String?
    internal let deliver: String?
}

/// A typed directed edge. Types: `reads` (source/artifact → cron), `writes`
/// (cron → artifact), `feeds` (cron → cron, via a `cron-output:<id>` input),
/// or a side-effect scheme (`telegram`, `pr`, …) for a cron → sink edge.
internal struct CronGraphEdge: Identifiable, Hashable {
    internal var id: String { "\(source)->\(target):\(type)" }
    internal let source: String
    internal let target: String
    internal let type: String
}

internal struct CronGraph {
    internal let nodes: [CronGraphNode]
    internal let edges: [CronGraphEdge]

    internal static let empty = CronGraph(nodes: [], edges: [])

    internal var isEmpty: Bool { nodes.isEmpty }
}

// MARK: - Per-job dataflow projection

/// One endpoint in a single job's dataflow: a resource it reads, an artifact it
/// writes, a sink it drives, or another cron in its feed chain. `kind` drives the
/// chip color (matching the graph's node palette); `type` is the fine-grained
/// scheme shown as a badge (`https`, `wiki`, `telegram`, `pr`, …).
internal struct CronDataflowEndpoint: Identifiable, Hashable {
    internal let id: String
    internal let label: String
    internal let kind: String
    internal let type: String
}

/// A single cron's inputs, outputs, and side effects, projected from the graph
/// edges — the same relationships the interflow graph draws, gathered for one job
/// so a cron card can list its own dataflow without holding the whole graph.
internal struct CronJobDataflow: Equatable {
    internal var reads: [CronDataflowEndpoint] = []
    internal var writes: [CronDataflowEndpoint] = []
    internal var sideEffects: [CronDataflowEndpoint] = []
    /// Downstream crons that consume this job's output.
    internal var feeds: [CronDataflowEndpoint] = []
    /// Upstream crons whose output this job consumes.
    internal var fedBy: [CronDataflowEndpoint] = []

    internal static let empty = CronJobDataflow()

    internal var isEmpty: Bool {
        reads.isEmpty && writes.isEmpty && sideEffects.isEmpty && feeds.isEmpty && fedBy.isEmpty
    }
}

extension CronGraph {
    /// Project the graph onto one cron: resolve every edge touching `cronID` into
    /// a typed endpoint (reads / writes / side-effect / feeds), skipping edges
    /// whose far end isn't a known node. Endpoints dedupe within each bucket,
    /// preserving first-seen order.
    internal func dataflow(forCronID cronID: String) -> CronJobDataflow {
        guard !cronID.isEmpty else { return .empty }
        let nodeByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var flow = CronJobDataflow()
        var seen: Set<String> = []

        func endpoint(_ node: CronGraphNode, typeOverride: String? = nil) -> CronDataflowEndpoint {
            CronDataflowEndpoint(id: node.id, label: node.label, kind: node.kind, type: typeOverride ?? node.type)
        }
        func add(_ endpoint: CronDataflowEndpoint, to bucket: inout [CronDataflowEndpoint], key: String) {
            guard seen.insert("\(key)\u{1}\(endpoint.id)").inserted else { return }
            bucket.append(endpoint)
        }

        for edge in edges {
            switch edge.type {
            case "reads":
                guard edge.target == cronID, let node = nodeByID[edge.source] else { continue }
                add(endpoint(node), to: &flow.reads, key: "reads")
            case "writes":
                guard edge.source == cronID, let node = nodeByID[edge.target] else { continue }
                add(endpoint(node), to: &flow.writes, key: "writes")
            case "feeds":
                if edge.source == cronID, let node = nodeByID[edge.target] {
                    add(endpoint(node), to: &flow.feeds, key: "feeds")
                } else if edge.target == cronID, let node = nodeByID[edge.source] {
                    add(endpoint(node), to: &flow.fedBy, key: "fedBy")
                }
            default:
                // Every other type is a side-effect scheme (telegram / pr / …) on a
                // cron → sink edge; the edge type is the scheme, so it wins over the
                // sink node's generic type for the badge.
                guard edge.source == cronID, let node = nodeByID[edge.target] else { continue }
                add(endpoint(node, typeOverride: edge.type), to: &flow.sideEffects, key: "side")
            }
        }
        return flow
    }
}
