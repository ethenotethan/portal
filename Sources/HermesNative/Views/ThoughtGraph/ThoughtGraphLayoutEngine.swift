import Foundation
import SwiftUI

// MARK: - Graph Edge

/// A directed edge in the thought graph, tagged with how it should render.
struct ThoughtGraphEdge: Equatable {
    enum Kind: Equatable {
        /// Sequential step in the main loop (inferred order) — dashed.
        case main
        /// Dispatch from a delegating tool call to a subagent — solid, bold.
        case spawn
        /// Sequential step inside a subagent's loop — solid, quiet.
        case loop
    }

    let from: String
    let to: String
    let kind: Kind
}

// MARK: - Lane Info

/// One vertical swimlane: the main loop or a single subagent's loop.
struct ThoughtGraphLane: Identifiable {
    let id: String          // "main" or the subagent_id
    let index: Int
    let x: Double           // lane center in world space
    let title: String       // "main loop" or the agent goal prefix
    let isAgent: Bool
    var minY: Double
    var maxY: Double
}

// MARK: - ThoughtGraphLayoutEngine

/// Swimlane/timeline layout engine for the live agent thought graph.
///
/// The graph reads as a story rather than an inferred dependency DAG:
///
/// - **Lanes (x-axis)** — one column per actor. The main react loop owns the
///   first lane; every spawned subagent gets its own lane to the right, in
///   spawn order. Recursion reads as lanes spawning lanes.
/// - **Time (y-axis)** — every node (tool call, reasoning beat, agent spawn)
///   occupies its own chronological row, ordered by `startedAt` (falling back
///   to arrival order). Parallel work shows as adjacent lanes advancing
///   through the same time band.
/// - **Edges** — consecutive nodes within a lane chain vertically (`main` /
///   `loop` kinds); a subagent's lane connects back to the delegating tool
///   call with a `spawn` edge. No cross-lane dependency inference: every edge
///   drawn is real.
///
/// The engine is pure geometry: filtering (collapsed agents, hidden
/// reasoning) happens in the view before `layout(nodes:)` is called.
@MainActor
final class ThoughtGraphLayoutEngine: ObservableObject {

    // MARK: - Published State

    /// Computed layout positions for every node, keyed by node ID.
    @Published var layouts: [ThoughtGraphLayout] = []

    /// Typed edges (lane chains + spawn edges).
    @Published var edges: [ThoughtGraphEdge] = []

    /// Swimlanes, main first, then agents in spawn order.
    @Published var lanes: [ThoughtGraphLane] = []

    /// Total bounding size of the laid-out graph (including padding).
    @Published var totalSize: CGSize = .zero

    // MARK: - Layout Constants

    /// Width × height of every node rectangle.
    static let nodeSize = CGSize(width: 150, height: 52)

    /// Horizontal distance between lane centers.
    static let lanePitch: Double = 220

    /// Vertical distance between consecutive chronological rows.
    static let rowPitch: Double = 76

    // MARK: - Private Storage

    private var nodeIndex: [String: ThoughtGraphNode] = [:]
    private var layoutIndex: [String: ThoughtGraphLayout] = [:]

    init() {}

    // MARK: - Layout Computation

    /// Run the swimlane/timeline layout on the given nodes.
    func layout(nodes: [ThoughtGraphNode]) {
        nodeIndex = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        guard !nodes.isEmpty else {
            layouts = []
            edges = []
            lanes = []
            totalSize = .zero
            return
        }

        // ---- 1. Chronological order ----
        // startedAt when present; otherwise keep arrival order by synthesizing
        // an epoch-offset key from the array index (history entries have no
        // timestamps).
        let ordered = nodes.enumerated().sorted { a, b in
            let ta = a.element.startedAt?.timeIntervalSinceReferenceDate
                ?? Double(a.offset) * 0.001
            let tb = b.element.startedAt?.timeIntervalSinceReferenceDate
                ?? Double(b.offset) * 0.001
            if ta != tb { return ta < tb }
            return a.offset < b.offset
        }.map(\.element)

        // ---- 2. Lane assignment ----
        // Main lane first, then one lane per agent in first-appearance order.
        var laneOrder: [String] = ["main"]
        var laneIndexByKey: [String: Int] = ["main": 0]
        for node in ordered {
            guard let key = node.agentID ?? node.ownerAgentID else { continue }
            if laneIndexByKey[key] == nil {
                laneIndexByKey[key] = laneOrder.count
                laneOrder.append(key)
            }
        }
        let laneCount = laneOrder.count
        let laneCenterOffset = Double(laneCount - 1) * Self.lanePitch / 2

        func laneX(_ index: Int) -> Double {
            Double(index) * Self.lanePitch - laneCenterOffset
        }

        // ---- 3. Rows: one per node, chronological ----
        var layoutResults: [ThoughtGraphLayout] = []
        var lastNodeIDInLane: [Int: String] = [:]
        var laneMinY: [Int: Double] = [:]
        var laneMaxY: [Int: Double] = [:]
        var computedEdges: [ThoughtGraphEdge] = []
        var lastMainNodeID: String?
        var rowByID: [String: Int] = [:]

        for (row, node) in ordered.enumerated() {
            let laneKey = node.agentID ?? node.ownerAgentID ?? "main"
            let laneIdx = laneIndexByKey[laneKey] ?? 0
            let x = laneX(laneIdx)
            let y = Double(row) * Self.rowPitch

            layoutResults.append(ThoughtGraphLayout(
                nodeID: node.id,
                x: x, y: y,
                width: Self.nodeSize.width,
                height: Self.nodeSize.height
            ))
            rowByID[node.id] = row
            laneMinY[laneIdx] = min(laneMinY[laneIdx] ?? y, y)
            laneMaxY[laneIdx] = max(laneMaxY[laneIdx] ?? y, y)

            // ---- Edges ----
            if node.isAgent {
                // Spawn edge: explicit delegating parent when it exists in
                // this node set, else the most recent main-lane node so the
                // dispatch still reads as "spawned from the loop here".
                if let pid = node.parentIDs.first(where: { nodeIndex[$0] != nil }) {
                    computedEdges.append(.init(from: pid, to: node.id, kind: .spawn))
                } else if let fallback = lastMainNodeID {
                    computedEdges.append(.init(from: fallback, to: node.id, kind: .spawn))
                }
            } else if let prev = lastNodeIDInLane[laneIdx] {
                computedEdges.append(.init(
                    from: prev, to: node.id,
                    kind: laneIdx == 0 ? .main : .loop
                ))
            }

            lastNodeIDInLane[laneIdx] = node.id
            if laneIdx == 0 { lastMainNodeID = node.id }
        }

        // Persist row into the node's depth field for callers that inspect it.
        for i in layoutResults.indices {
            if var node = nodeIndex[layoutResults[i].nodeID] {
                node.depth = rowByID[node.id] ?? 0
                nodeIndex[node.id] = node
            }
        }

        // ---- 4. Lane metadata (for backgrounds + headers) ----
        var laneInfos: [ThoughtGraphLane] = []
        for (idx, key) in laneOrder.enumerated() {
            guard let minY = laneMinY[idx], let maxY = laneMaxY[idx] else { continue }
            let title: String
            let isAgent = key != "main"
            if isAgent {
                let goal = nodeIndex[SubagentGraphIntegrator.agentNodeID(for: key)]?.context ?? ""
                title = goal.isEmpty ? "agent" : String(goal.prefix(28))
            } else {
                title = "main loop"
            }
            laneInfos.append(ThoughtGraphLane(
                id: key, index: idx, x: laneX(idx),
                title: title, isAgent: isAgent,
                minY: minY, maxY: maxY
            ))
        }

        // ---- 5. Publish ----
        layouts = layoutResults
        layoutIndex = Dictionary(uniqueKeysWithValues: layoutResults.map { ($0.nodeID, $0) })
        edges = computedEdges
        lanes = laneInfos

        let width = Double(laneCount) * Self.lanePitch + Self.nodeSize.width
        let height = Double(ordered.count) * Self.rowPitch + Self.nodeSize.height * 2
        totalSize = CGSize(width: max(width, 200), height: max(height, 200))
    }

    // MARK: - Edge Geometry

    /// Control points for the quadratic bezier connecting two nodes.
    /// Within-lane edges run bottom-center → top-center; cross-lane spawn
    /// edges leave the parent's side toward the child lane for a clean fan-out.
    func edgeControlPoints(from parentID: String, to childID: String)
        -> (start: CGPoint, control: CGPoint, end: CGPoint)? {
        guard let p = layoutIndex[parentID], let c = layoutIndex[childID] else { return nil }

        let sameLane = abs(p.x - c.x) < 1
        let start: CGPoint
        let end: CGPoint
        if sameLane {
            start = CGPoint(x: p.x, y: p.y + p.height / 2)
            end = CGPoint(x: c.x, y: c.y - c.height / 2)
        } else {
            // Leave the parent from the side facing the child's lane.
            let dir: CGFloat = c.x > p.x ? 1 : -1
            start = CGPoint(x: p.x + dir * p.width / 2, y: p.y)
            end = CGPoint(x: c.x, y: c.y - c.height / 2)
        }

        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = max(hypot(dx, dy), 1)
        // Cross-lane edges bow harder so they arc around lane contents.
        let bow: CGFloat = sameLane ? min(len * 0.12, 26) : min(len * 0.25, 60)
        let ctrl = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)
        return (start, ctrl, end)
    }

    /// Curved edge path between two nodes.
    func edgePath(from parentID: String, to childID: String) -> Path {
        guard let pts = edgeControlPoints(from: parentID, to: childID) else { return Path() }
        var path = Path()
        path.move(to: pts.start)
        path.addQuadCurve(to: pts.end, control: pts.control)
        return path
    }

    /// Point at parameter `t` (0...1) along an edge's quadratic bezier —
    /// used for flow particles.
    func edgePoint(from parentID: String, to childID: String, t: CGFloat) -> CGPoint? {
        guard let pts = edgeControlPoints(from: parentID, to: childID) else { return nil }
        let u = 1 - t
        let x = u * u * pts.start.x + 2 * u * t * pts.control.x + t * t * pts.end.x
        let y = u * u * pts.start.y + 2 * u * t * pts.control.y + t * t * pts.end.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Helpers

    /// Lookup the `ThoughtGraphLayout` for a given node ID.
    func layout(for nodeID: String) -> ThoughtGraphLayout? {
        layoutIndex[nodeID]
    }

    // MARK: - Timeline Composition

    /// Compose the full node timeline for one turn: main-loop tool calls,
    /// subagent subtrees, and reasoning beats, all interleaved
    /// chronologically by `layout(nodes:)`.
    static func composeTimeline(
        tools: [ToolCallRecord],
        agentNodes: [ThoughtGraphNode] = [],
        reasoningNodes: [ThoughtGraphNode] = []
    ) -> [ThoughtGraphNode] {
        var nodes = tools.map { ThoughtGraphNode.from(toolCall: $0) }
        nodes.append(contentsOf: agentNodes)
        nodes.append(contentsOf: reasoningNodes)
        return nodes
    }

    // MARK: - Category Classification

    /// Tool category used for color coding.
    enum ToolCategory: String {
        case search  // search_files, web_search, grep, find
        case read    // read_file, cat, open
        case write   // write_file, create, save
        case patch   // patch, edit, replace, diff
        case terminal // terminal, shell, exec, bash, run
        case agent   // delegate/spawn/subagent dispatch tools + agent nodes
        case reasoning // interleaved thought beats
        case other   // everything else

        /// Classify a tool by its name.
        static func classify(name: String) -> ToolCategory {
            let lower = name.lowercased()
            if lower == "reasoning" {
                return .reasoning
            }
            if lower.contains("delegate") || lower.contains("subagent") || lower.contains("spawn") {
                return .agent
            }
            if lower.contains("search") || lower.contains("web") || lower.contains("grep") || lower.contains("find") || lower.contains("list_files") {
                return .search
            }
            if lower.contains("read") || lower.contains("cat") || lower.hasPrefix("open") {
                return .read
            }
            if lower.contains("write") || lower.contains("create") || lower.contains("save") || lower.contains("mkdir") {
                return .write
            }
            if lower.contains("patch") || lower.contains("edit") || lower.contains("replace") || lower.contains("diff") || lower.contains("apply") {
                return .patch
            }
            if lower.contains("terminal") || lower.contains("shell") || lower.contains("exec") || lower.contains("bash") || lower.hasPrefix("run") || lower.hasPrefix("process") {
                return .terminal
            }
            return .other
        }

        /// Cohesive graph color ramp (see Theme).
        var color: Color {
            switch self {
            case .search:    Theme.graphSearch
            case .read:      Theme.graphRead
            case .write:     Theme.graphWrite
            case .patch:     Theme.graphPatch
            case .terminal:  Theme.graphTerminal
            case .agent:     Theme.agentAccent
            case .reasoning: Theme.graphReasoning
            case .other:     Theme.graphOther
            }
        }
    }
}
