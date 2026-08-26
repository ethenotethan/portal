import Foundation

// MARK: - CronGraphChange

/// One statement about how the dataflow changed between two revisions.
///
/// A graph isn't a file, so a unified text diff is the wrong primitive: line
/// noise about JSON key order would bury the one fact that matters, which is
/// usually "this job started reading something new". Each case here is a sentence
/// a person would actually say, and the phrasing lives on the model rather than
/// in the view so the drawer and the canvas can't describe the same change two
/// different ways.
internal enum CronGraphChange: Identifiable, Equatable {

    /// An edge plus the labels of both ends, resolved at diff time.
    ///
    /// The labels have to be captured here because a removed edge's endpoints may
    /// not exist in the current graph at all — a job deleted along with its
    /// wiring has no node left to look a name up in.
    internal struct EdgeStatement: Equatable {
        internal let edge: CronGraphEdge
        internal let sourceLabel: String
        internal let targetLabel: String
    }

    case jobAdded(id: String, name: String)
    case jobRemoved(id: String, name: String)
    /// The leaf changed (or the leaf *and* the path) — a change of identity.
    case jobRenamed(id: String, from: String, to: String)
    /// Only the path changed: same job, refiled. See `classify(_:_:)`.
    case jobMoved(id: String, title: String, to: [String])
    case scheduleChanged(id: String, name: String, from: String?, to: String?)
    case enabledChanged(id: String, name: String, isEnabled: Bool)
    case modelUseChanged(id: String, name: String, usesLLM: Bool)
    case deliveryChanged(id: String, name: String, from: String?, to: String?)
    case descriptionChanged(id: String, name: String)
    case serviceAppeared(id: String, name: String)
    case serviceDisappeared(id: String, name: String)
    /// A source / artifact / sink that came or went *without* any edge change
    /// naming it. See `CronGraphDiff.resourceChanges(…)` for why those are the
    /// only ones stated.
    case resourceAppeared(id: String, name: String)
    case resourceDisappeared(id: String, name: String)
    case edgeAdded(EdgeStatement)
    case edgeRemoved(EdgeStatement)

    // MARK: - Identity

    internal var id: String {
        switch self {
        case .jobAdded(let id, _):            return "job+\(id)"
        case .jobRemoved(let id, _):          return "job-\(id)"
        case .jobRenamed(let id, _, _):       return "rename\(id)"
        case .jobMoved(let id, _, _):         return "move\(id)"
        case .scheduleChanged(let id, _, _, _): return "schedule\(id)"
        case .enabledChanged(let id, _, _):   return "enabled\(id)"
        case .modelUseChanged(let id, _, _):  return "model\(id)"
        case .deliveryChanged(let id, _, _, _): return "deliver\(id)"
        case .descriptionChanged(let id, _):  return "description\(id)"
        case .serviceAppeared(let id, _):     return "service+\(id)"
        case .serviceDisappeared(let id, _):  return "service-\(id)"
        case .resourceAppeared(let id, _):    return "resource+\(id)"
        case .resourceDisappeared(let id, _): return "resource-\(id)"
        case .edgeAdded(let statement):       return "edge+\(statement.edge.id)"
        case .edgeRemoved(let statement):     return "edge-\(statement.edge.id)"
        }
    }

    /// Whether this change adds, removes, or alters something — the axis the UI
    /// tints on, so a diff reads at a glance before it's read at all.
    internal enum Polarity { case added, removed, modified }

    internal var polarity: Polarity {
        switch self {
        case .jobAdded, .serviceAppeared, .resourceAppeared, .edgeAdded:
            return .added
        case .jobRemoved, .serviceDisappeared, .resourceDisappeared, .edgeRemoved:
            return .removed
        case .jobRenamed, .jobMoved, .scheduleChanged, .enabledChanged,
             .modelUseChanged, .deliveryChanged, .descriptionChanged:
            return .modified
        }
    }

    /// The nodes this change is about — both ends for an edge. Feeds the canvas
    /// highlight, which is why it includes endpoints rather than just subjects: an
    /// edge lighting up with only one lit node reads as a bug.
    internal var nodeIDs: [String] {
        switch self {
        case .jobAdded(let id, _), .jobRemoved(let id, _), .jobRenamed(let id, _, _),
             .jobMoved(let id, _, _), .scheduleChanged(let id, _, _, _),
             .enabledChanged(let id, _, _), .modelUseChanged(let id, _, _),
             .deliveryChanged(let id, _, _, _), .descriptionChanged(let id, _),
             .serviceAppeared(let id, _), .serviceDisappeared(let id, _),
             .resourceAppeared(let id, _), .resourceDisappeared(let id, _):
            return [id]
        case .edgeAdded(let statement), .edgeRemoved(let statement):
            return [statement.edge.source, statement.edge.target]
        }
    }

    /// Sort rank, so a diff always reads in the same order: what exists first,
    /// then how it's configured, then how it's wired. Two runs over the same pair
    /// of revisions must produce identical output — a diff that reshuffles itself
    /// can't be compared against the one in yesterday's screenshot.
    internal var rank: Int {
        switch self {
        case .jobAdded:            return 0
        case .jobRemoved:          return 1
        case .jobRenamed:          return 2
        case .jobMoved:            return 3
        case .scheduleChanged:     return 4
        case .enabledChanged:      return 5
        case .modelUseChanged:     return 6
        case .deliveryChanged:     return 7
        case .descriptionChanged:  return 8
        case .serviceAppeared:     return 9
        case .serviceDisappeared:  return 10
        case .resourceAppeared:    return 11
        case .resourceDisappeared: return 12
        case .edgeAdded:           return 13
        case .edgeRemoved:         return 14
        }
    }
}

// MARK: - Phrasing

extension CronGraphChange {

    /// The sentence shown in a diff row.
    internal var summary: String {
        switch self {
        case .jobAdded(_, let name):
            return "\(name) added"
        case .jobRemoved(_, let name):
            return "\(name) removed"
        case .jobRenamed(_, let from, let to):
            return "\(from) renamed to \(to)"
        case .jobMoved(_, let title, let path):
            // `displayPath` renders the root as "Ungrouped", so a job pulled out
            // of every folder still reads as a destination rather than a blank.
            return "\(title) moved to \(CronCategory.displayPath(path))"
        case .scheduleChanged(_, let name, let from, let to):
            return "\(name) runs \(Self.scheduleText(to)) (was \(Self.scheduleText(from)))"
        case .enabledChanged(_, let name, let isEnabled):
            return "\(name) \(isEnabled ? "enabled" : "disabled")"
        case .modelUseChanged(_, let name, let usesLLM):
            return usesLLM ? "\(name) now burns a model" : "\(name) no longer burns a model"
        case .deliveryChanged(_, let name, let from, let to):
            guard let to, !to.isEmpty else { return "\(name) no longer delivers anywhere" }
            guard let from, !from.isEmpty else { return "\(name) now delivers to \(to)" }
            return "\(name) delivers to \(to) (was \(from))"
        case .descriptionChanged(_, let name):
            return "\(name) description edited"
        case .serviceAppeared(_, let name):
            return "\(name) service appeared"
        case .serviceDisappeared(_, let name):
            return "\(name) service disappeared"
        case .resourceAppeared(_, let name):
            return "\(name) appeared"
        case .resourceDisappeared(_, let name):
            return "\(name) disappeared"
        case .edgeAdded(let statement):
            return statement.sentence(isAddition: true)
        case .edgeRemoved(let statement):
            return statement.sentence(isAddition: false)
        }
    }

    /// A missing schedule and an empty one are different things and the digest
    /// treats them as such, so the sentence has to as well.
    private static func scheduleText(_ schedule: String?) -> String {
        guard let schedule else { return "on no schedule" }
        return schedule.isEmpty ? "on a cleared schedule" : schedule
    }
}

extension CronGraphChange.EdgeStatement {

    /// Stated as dataflow rather than as graph mechanics: "solana sweep now reads
    /// x402" is the change someone made; "edge added wiki:x402→abc123" is the
    /// representation of it. The verb comes from the edge type, and the subject
    /// from which end the job is on — `reads` points at the job, everything else
    /// points away from it.
    internal func sentence(isAddition: Bool) -> String {
        let now = isAddition ? "now" : "no longer"
        switch edge.type {
        case "reads":
            return "\(targetLabel) \(now) reads \(sourceLabel)"
        case "writes":
            return "\(sourceLabel) \(now) writes \(targetLabel)"
        case "feeds":
            return "\(sourceLabel) \(now) feeds \(targetLabel)"
        default:
            // Any other type is a side-effect scheme on a cron → sink edge, and
            // the scheme is the interesting part: "via telegram" is the change.
            return "\(sourceLabel) \(now) delivers to \(targetLabel) via \(edge.type)"
        }
    }
}

// MARK: - CronGraphDiff

/// The structural difference between two revisions of the dataflow graph.
///
/// Nodes are matched by `id`, which is what makes rename detection possible at
/// all: a cron's id is its job id, so renaming it keeps the node and changes the
/// label. Resource ids *are* their content (`wiki:x402`), so a "renamed" artifact
/// is honestly an add plus a remove — there is no identity underneath the name to
/// carry across.
internal struct CronGraphDiff: Equatable {

    /// Every statement, in `rank` order and stable within a rank.
    internal let changes: [CronGraphChange]

    internal var isEmpty: Bool { changes.isEmpty }
    internal var count: Int { changes.count }

    /// Nodes touched by any change — the set the canvas tints. Derived from the
    /// statements themselves rather than recomputed, so what lights up can't
    /// drift from what the drawer says changed.
    internal var affectedNodeIDs: Set<String> {
        Set(changes.flatMap(\.nodeIDs))
    }

    /// Edges that appeared, by `CronGraphEdge.id` — drawn highlighted, since they
    /// exist in the current graph.
    internal var addedEdgeIDs: Set<String> {
        Set(changes.compactMap {
            guard case .edgeAdded(let statement) = $0 else { return nil }
            return statement.edge.id
        })
    }

    /// Edges that went away. Kept as whole edges rather than ids because they are
    /// *not* in the graph being drawn: a ghosted dashed line has to be
    /// reconstructed from the diff or it can't be drawn at all.
    internal var removedEdges: [CronGraphEdge] {
        changes.compactMap {
            guard case .edgeRemoved(let statement) = $0 else { return nil }
            return statement.edge
        }
    }

    /// How a single node changed, for tinting it on the canvas — nil when no
    /// statement names it.
    ///
    /// A node can be named by several statements at once (renamed *and*
    /// rescheduled, or newly added *and* wired up), so one has to win, and the
    /// strongest claim does: something here is new, then something here is gone,
    /// then something here was edited. A single color can't carry three facts, so
    /// it carries the loudest one and the drawer lists all of them — the list is
    /// what's authoritative, the tint only says where to look.
    internal func polarity(forNodeID id: String) -> CronGraphChange.Polarity? {
        let polarities = changes.filter { $0.nodeIDs.contains(id) }.map(\.polarity)
        for candidate in [CronGraphChange.Polarity.added, .removed, .modified]
        where polarities.contains(candidate) {
            return candidate
        }
        return nil
    }

    internal static let empty = CronGraphDiff(changes: [])

    // MARK: - Computing

    internal static func between(_ before: CronGraph, _ after: CronGraph) -> CronGraphDiff {
        let beforeNodes = Dictionary(before.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterNodes = Dictionary(after.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var changes: [CronGraphChange] = []
        for node in after.nodes where beforeNodes[node.id] == nil {
            changes.append(appearance(of: node, appeared: true))
        }
        for node in before.nodes where afterNodes[node.id] == nil {
            changes.append(appearance(of: node, appeared: false))
        }
        for node in after.nodes {
            guard let old = beforeNodes[node.id] else { continue }
            changes.append(contentsOf: fieldChanges(from: old, to: node))
        }
        changes.append(contentsOf: edgeChanges(before, after, beforeNodes, afterNodes))

        // Resource statements are only kept where no edge already names them.
        changes = suppressingRedundantResources(changes)
        changes.sort { ($0.rank, $0.id) < ($1.rank, $1.id) }
        return CronGraphDiff(changes: changes)
    }

    /// What a node coming or going is *called*, which depends on what it is: a job
    /// and a service are things someone created or deleted, while a source or
    /// artifact is a consequence of wiring.
    private static func appearance(of node: CronGraphNode, appeared: Bool) -> CronGraphChange {
        switch node.kind {
        case "cron":
            return appeared
                ? .jobAdded(id: node.id, name: node.label)
                : .jobRemoved(id: node.id, name: node.label)
        case "service":
            return appeared
                ? .serviceAppeared(id: node.id, name: node.label)
                : .serviceDisappeared(id: node.id, name: node.label)
        default:
            return appeared
                ? .resourceAppeared(id: node.id, name: node.label)
                : .resourceDisappeared(id: node.id, name: node.label)
        }
    }

    /// Per-field statements for a node that exists in both revisions. Every field
    /// the commitment covers is checked here, deliberately: a change that mints a
    /// revision and then produces an empty diff would leave the log asserting that
    /// something happened while refusing to say what.
    private static func fieldChanges(
        from old: CronGraphNode,
        to new: CronGraphNode
    ) -> [CronGraphChange] {
        var changes: [CronGraphChange] = []
        if old.label != new.label {
            changes.append(classify(rename: old, to: new))
        }
        if old.schedule != new.schedule {
            changes.append(.scheduleChanged(id: new.id, name: new.label,
                                            from: old.schedule, to: new.schedule))
        }
        if old.enabled != new.enabled {
            changes.append(.enabledChanged(id: new.id, name: new.label, isEnabled: new.enabled))
        }
        if old.usesLLM != new.usesLLM {
            changes.append(.modelUseChanged(id: new.id, name: new.label, usesLLM: new.usesLLM))
        }
        if old.deliver != new.deliver {
            changes.append(.deliveryChanged(id: new.id, name: new.label,
                                            from: old.deliver, to: new.deliver))
        }
        if old.description != new.description {
            // The text itself isn't diffed: a service blurb is markdown prose, and
            // a word-level diff of it belongs to a reader, not to a change list.
            changes.append(.descriptionChanged(id: new.id, name: new.label))
        }
        return changes
    }

    /// Rename vs recategorize. Same leaf under a different path is a *move* — the
    /// category lives in the name (`CronCategory`), so refiling a job and renaming
    /// it are the same wire operation and only the shape of the change tells them
    /// apart. Calling a move a rename would report `projection/x402` →
    /// `indexing/x402` as a new identity when the job is the same job.
    ///
    /// A change to both path and leaf is reported as a rename: it *is* a change of
    /// identity, and the full names in the sentence show the move as well.
    private static func classify(rename old: CronGraphNode, to new: CronGraphNode) -> CronGraphChange {
        let from = CronCategory.split(name: old.label)
        let to = CronCategory.split(name: new.label)
        guard from.title == to.title, from.path != to.path else {
            return .jobRenamed(id: new.id, from: old.label, to: new.label)
        }
        return .jobMoved(id: new.id, title: to.title, to: to.path)
    }

    private static func edgeChanges(
        _ before: CronGraph,
        _ after: CronGraph,
        _ beforeNodes: [String: CronGraphNode],
        _ afterNodes: [String: CronGraphNode]
    ) -> [CronGraphChange] {
        let beforeEdges = Dictionary(before.edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterEdges = Dictionary(after.edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func label(_ id: String, _ primary: [String: CronGraphNode], _ fallback: [String: CronGraphNode]) -> String {
            // Falls back to the other revision, then to the raw id: an edge whose
            // endpoint node is missing from both is malformed, and printing the id
            // is more honest than printing nothing.
            primary[id]?.label ?? fallback[id]?.label ?? id
        }

        var changes: [CronGraphChange] = []
        for (id, edge) in afterEdges where beforeEdges[id] == nil {
            changes.append(.edgeAdded(CronGraphChange.EdgeStatement(
                edge: edge,
                sourceLabel: label(edge.source, afterNodes, beforeNodes),
                targetLabel: label(edge.target, afterNodes, beforeNodes)
            )))
        }
        for (id, edge) in beforeEdges where afterEdges[id] == nil {
            changes.append(.edgeRemoved(CronGraphChange.EdgeStatement(
                edge: edge,
                sourceLabel: label(edge.source, beforeNodes, afterNodes),
                targetLabel: label(edge.target, beforeNodes, afterNodes)
            )))
        }
        return changes
    }

    /// Drop resource statements whose node is already named by an edge change.
    ///
    /// An artifact exists *because* something writes it, so a new `wiki:x402`
    /// almost always arrives with "solana sweep now writes x402" beside it, and
    /// stating both says the same thing twice in a list where every line is meant
    /// to be a distinct fact. The ones with no edge to explain them are kept —
    /// an orphan resource appearing is odd, and odd is exactly what a diff should
    /// not swallow.
    private static func suppressingRedundantResources(
        _ changes: [CronGraphChange]
    ) -> [CronGraphChange] {
        var edgeEndpoints: Set<String> = []
        for change in changes {
            switch change {
            case .edgeAdded(let statement), .edgeRemoved(let statement):
                edgeEndpoints.insert(statement.edge.source)
                edgeEndpoints.insert(statement.edge.target)
            default:
                continue
            }
        }
        return changes.filter { change in
            switch change {
            case .resourceAppeared(let id, _), .resourceDisappeared(let id, _):
                return !edgeEndpoints.contains(id)
            default:
                return true
            }
        }
    }
}
