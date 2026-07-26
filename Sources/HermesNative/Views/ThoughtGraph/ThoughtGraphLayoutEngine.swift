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

/// One horizontal swimlane: the main loop or a single subagent's loop. Lanes
/// stack down the y-axis; time runs left→right across each lane.
struct ThoughtGraphLane: Identifiable {
    internal let id: String       // "main" or the subagent_id
    internal let index: Int
    internal let y: Double        // lane center in world space (row)
    internal let title: String    // "main loop" or the agent goal prefix
    internal let isAgent: Bool
    internal var minX: Double     // left edge of this lane's first bar
    internal var maxX: Double     // right edge of this lane's last bar
}

// MARK: - ThoughtGraphLayoutEngine

/// Time-plot swimlane layout engine for the live agent thought graph.
///
/// The graph reads as a flamechart of the react loop — a box's horizontal
/// position is WHEN it happened and its width is HOW LONG it took:
///
/// - **Time (x-axis)** — a node's left edge is `(startedAt − t0)` scaled by
///   `pixelsPerSecond`; its width is its duration on the same scale, floored
///   at `minBarWidth` so a 40 ms call never vanishes. Gaps between bars are
///   real idle/wait time. Running nodes have no end yet — the view extends
///   their right edge to "now" each frame (see `runningWidth`).
/// - **Lanes (y-axis)** — one row per actor, stacked by spawn order. The main
///   react loop owns the top lane; every spawned subagent opens its own lane
///   below, beginning at the x where it was dispatched.
/// - **Edges** — a subagent's lane connects back to the delegating tool call
///   with a `spawn` edge (a diagonal from the parent's right edge down into
///   the child lane). Sequence within a lane is shown by left→right adjacency,
///   so within-lane edges aren't drawn — the time axis already orders them.
///
/// The engine is pure geometry: filtering (collapsed agents, hidden
/// reasoning) happens in the view before `layout(nodes:)` is called.
@MainActor
final class ThoughtGraphLayoutEngine: ObservableObject {

    // MARK: - Published State

    /// Computed layout positions for every node, keyed by node ID.
    /// `x` is the bar's LEFT edge (time start); `y` is the lane center.
    @Published internal var layouts: [ThoughtGraphLayout] = []

    /// Typed edges (spawn edges from a delegating tool to a subagent lane).
    @Published internal var edges: [ThoughtGraphEdge] = []

    /// Swimlanes, main first, then agents in spawn order.
    @Published internal var lanes: [ThoughtGraphLane] = []

    /// Total bounding size of the laid-out graph (including padding).
    @Published internal var totalSize: CGSize = .zero

    /// Wall-clock time mapped to world x = 0 (the earliest node's start).
    /// The view needs this to extend running bars to "now".
    @Published internal var timeOrigin: Date?

    // MARK: - Layout Constants

    /// Size of the detail-popover card (NOT the timeline bar — bars are
    /// variable-width). Kept so the popover renders a full node card.
    internal static let nodeSize = CGSize(width: 150, height: 52)

    /// Vertical distance between lane centers.
    internal static let laneHeight: Double = 66

    /// Thickness of a tool/agent bar.
    internal static let barHeight: Double = 30

    /// Linear time scale: world pixels per second of duration.
    internal static let pixelsPerSecond: Double = 46

    /// Minimum bar width so sub-100 ms calls stay tappable and visible.
    internal static let minBarWidth: Double = 7

    /// Edge size of a reasoning-beat diamond (durationless, point-in-time).
    internal static let markerSize: Double = 16

    /// Padding before the first bar (space for t=0).
    internal static let leftGutter: Double = 12

    /// Synthetic seconds-per-node when nodes lack real timestamps (history
    /// snapshots) — keeps them ordered left→right with readable spacing.
    private static let syntheticStep: Double = 1.2

    // MARK: - Private Storage

    private var nodeIndex: [String: ThoughtGraphNode] = [:]
    private var layoutIndex: [String: ThoughtGraphLayout] = [:]

    internal init() {}

    // MARK: - Layout Computation

    /// Run the time-plot swimlane layout on the given nodes. `now` bounds the
    /// right edge of still-running bars at layout time; the view keeps them
    /// growing between layouts.
    internal func layout(nodes: [ThoughtGraphNode], now: Date = Date()) {
        nodeIndex = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })

        guard !nodes.isEmpty else {
            layouts = []
            edges = []
            lanes = []
            totalSize = .zero
            timeOrigin = nil
            return
        }

        // ---- 1. Chronological order ----
        // startedAt when present; otherwise keep arrival order by synthesizing
        // an epoch-offset key from the array index (history entries have no
        // timestamps).
        let orderedPairs = nodes.enumerated().sorted { a, b in
            let ta = a.element.startedAt?.timeIntervalSinceReferenceDate
                ?? Double(a.offset) * 0.001
            let tb = b.element.startedAt?.timeIntervalSinceReferenceDate
                ?? Double(b.offset) * 0.001
            if ta != tb { return ta < tb }
            return a.offset < b.offset
        }
        let ordered = orderedPairs.map(\.element)

        // ---- 2. Time origin ----
        // t0 = earliest real start; nodes without one fall back to a synthetic
        // ordinal clock so history still reads left→right.
        let t0 = ordered.compactMap(\.startedAt).min()
        timeOrigin = t0

        func startX(_ node: ThoughtGraphNode, ordinal: Int) -> Double {
            guard let t0, let started = node.startedAt else {
                return Self.leftGutter + Double(ordinal) * Self.syntheticStep * Self.pixelsPerSecond
            }
            return Self.leftGutter + started.timeIntervalSince(t0) * Self.pixelsPerSecond
        }

        func barWidth(_ node: ThoughtGraphNode) -> Double {
            if node.category == .reasoning { return Self.markerSize }
            let seconds: Double
            if let dur = node.durationSeconds {
                seconds = dur
            } else if let s = node.startedAt, let e = node.completedAt {
                seconds = e.timeIntervalSince(s)
            } else if let s = node.startedAt {
                seconds = max(0, now.timeIntervalSince(s))   // still running
            } else {
                seconds = 0
            }
            return max(Self.minBarWidth, seconds * Self.pixelsPerSecond)
        }

        // ---- 3. Lane assignment ----
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

        func laneY(_ index: Int) -> Double { Double(index) * Self.laneHeight }

        // ---- 4. Bars: positioned by time, stacked by lane ----
        var layoutResults: [ThoughtGraphLayout] = []
        var laneMinX: [Int: Double] = [:]
        var laneMaxX: [Int: Double] = [:]
        var computedEdges: [ThoughtGraphEdge] = []
        var lastMainNodeID: String?

        for (ordinal, node) in ordered.enumerated() {
            let laneKey = node.agentID ?? node.ownerAgentID ?? "main"
            let laneIdx = laneIndexByKey[laneKey] ?? 0
            let x = startX(node, ordinal: ordinal)
            let y = laneY(laneIdx)
            let isMarker = node.category == .reasoning
            let width = barWidth(node)
            let height = isMarker ? Self.markerSize : Self.barHeight

            layoutResults.append(ThoughtGraphLayout(
                nodeID: node.id, x: x, y: y, width: width, height: height
            ))
            laneMinX[laneIdx] = min(laneMinX[laneIdx] ?? x, x)
            laneMaxX[laneIdx] = max(laneMaxX[laneIdx] ?? (x + width), x + width)

            // Spawn edge: a subagent lane hangs off the delegating tool call
            // (explicit parent if present, else the most recent main node).
            if node.isAgent {
                if let pid = node.parentIDs.first(where: { nodeIndex[$0] != nil }) {
                    computedEdges.append(.init(from: pid, to: node.id, kind: .spawn))
                } else if let fallback = lastMainNodeID {
                    computedEdges.append(.init(from: fallback, to: node.id, kind: .spawn))
                }
            }
            if laneIdx == 0 { lastMainNodeID = node.id }
        }

        // ---- 5. Lane metadata (for backgrounds + headers) ----
        var laneInfos: [ThoughtGraphLane] = []
        for (idx, key) in laneOrder.enumerated() {
            let title: String
            let isAgent = key != "main"
            if isAgent {
                let goal = nodeIndex[SubagentGraphIntegrator.agentNodeID(for: key)]?.context ?? ""
                title = goal.isEmpty ? "agent" : String(goal.prefix(28))
            } else {
                title = "main loop"
            }
            laneInfos.append(ThoughtGraphLane(
                id: key, index: idx, y: laneY(idx),
                title: title, isAgent: isAgent,
                minX: laneMinX[idx] ?? 0,
                maxX: laneMaxX[idx] ?? 0
            ))
        }

        // ---- 6. Publish ----
        layouts = layoutResults
        layoutIndex = Dictionary(uniqueKeysWithValues: layoutResults.map { ($0.nodeID, $0) })
        edges = computedEdges
        lanes = laneInfos

        let maxRight = layoutResults.map { $0.x + $0.width }.max() ?? 200
        let width = maxRight + Self.leftGutter * 2
        let height = Double(laneCount) * Self.laneHeight + Self.barHeight
        totalSize = CGSize(width: max(width, 200), height: max(height, 120))
    }

    /// Live width of a bar for the current frame: completed bars use their
    /// laid-out width; a still-running bar grows rightward to `now`.
    internal func liveWidth(for node: ThoughtGraphNode, laidOut: Double, now: Date) -> Double {
        guard node.status == .running, node.category != .reasoning,
              let started = node.startedAt else { return laidOut }
        let seconds = max(0, now.timeIntervalSince(started))
        return max(Self.minBarWidth, seconds * Self.pixelsPerSecond)
    }

    // MARK: - Edge Geometry

    /// Control points for the quadratic bezier of a spawn edge: from the
    /// delegating bar's right edge, arcing down into the child lane's start.
    internal func edgeControlPoints(from parentID: String, to childID: String)
        -> (start: CGPoint, control: CGPoint, end: CGPoint)? {
        guard let p = layoutIndex[parentID], let c = layoutIndex[childID] else { return nil }
        // Parent right-center → child left-center (bars are left-anchored).
        let start = CGPoint(x: p.x + p.width, y: p.y)
        let end = CGPoint(x: c.x, y: c.y)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = max(hypot(dx, dy), 1)
        let bow: CGFloat = min(len * 0.22, 46)
        let ctrl = CGPoint(x: mid.x + dy / len * bow, y: mid.y - dx / len * bow)
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
