import Foundation
import SwiftUI

// MARK: - ThoughtGraphLayoutEngine

/// Layered DAG layout engine for the live agent thought graph visualization.
///
/// The engine takes an array of `ThoughtGraphNode` objects and computes
/// positions for rendering them as a directed acyclic graph in a SwiftUI
/// `Canvas`. The layout uses a top-to-bottom layered (Sugiyama-style)
/// approach:
///
/// - **Root nodes** (depth 0, no parents) form the top layer, evenly spaced
///   horizontally and centered around x = 0.
/// - **Each subsequent depth** is positioned below the previous layer, with
///   nodes centered under the average x of their parent nodes.
/// - **Minimum gaps** are enforced between sibling nodes at the same depth
///   (horizontal: 80 pts) and between depth levels (vertical: 120 pts).
/// - **The entire graph is centered around the origin** (0,0) so the Canvas
///   `translate`/`scale` handles pan and zoom positioning.
///
/// Edges are **inferred** rather than explicitly tracked, and the engine
/// returns raw `Path` objects for quadratic bezier curves connecting parent
/// bottom-centers to child top-centers. The owning view is expected to stroke
/// these paths with a dashed style to indicate inferred edges.
///
/// ## Usage (from a SwiftUI `Canvas`):
/// ```swift
/// Canvas { context, size in
///     engine.layout(nodes: thoughtGraph.nodes)
///     context.translateBy(x: panOffset.width, y: panOffset.height)
///     context.scaleBy(x: zoom, y: zoom)
///
///     // Draw dashed edges
///     for (from, to) in engine.edges {
///         let path = engine.edgePath(from: from, to: to)
///         context.stroke(
///             path,
///             with: .color(edgeColor),
///             style: StrokeStyle(lineWidth: 1.0, dash: [6, 4])
///         )
///     }
///
///     // Draw nodes …
/// }
/// ```
@MainActor
final class ThoughtGraphLayoutEngine: ObservableObject {

    // MARK: - Published State

    /// Computed layout positions for every node, keyed by node ID.
    /// The owning `ThoughtGraphView` observes this array to reactively
    /// update the Canvas when positions change.
    @Published var layouts: [ThoughtGraphLayout] = []

    /// Inferred parent → child edge pairs.
    @Published var edges: [(from: String, to: String)] = []

    /// Total bounding size of the laid-out graph (including padding).
    /// Useful for sizing the Canvas or clamping scroll extents.
    @Published var totalSize: CGSize = .zero

    // MARK: - Layout Constants

    /// Width × height of every node rectangle.
    static let nodeSize = CGSize(width: 150, height: 52)

    /// Minimum horizontal distance between sibling nodes at the same depth.
    static let minHorizontalGap: Double = 80

    /// Minimum vertical distance between consecutive depth levels.
    static let minVerticalGap: Double = 120

    // MARK: - Private Storage

    /// The nodes most recently passed to `layout(nodes:)`.
    private var nodes: [ThoughtGraphNode] = []

    /// Lookup from node ID → `ThoughtGraphNode`.
    private var nodeIndex: [String: ThoughtGraphNode] = [:]

    /// Lookup from node ID → `ThoughtGraphLayout` for fast edge-path queries.
    private var layoutIndex: [String: ThoughtGraphLayout] = [:]

    // MARK: - Initializer

    init() {}

    // MARK: - Layout Computation

    /// Run the full DAG layout pipeline on the given nodes.
    ///
    /// - Parameter nodes: The tool-call nodes to lay out. An empty array
    ///   produces an empty layout with zero total size.
    func layout(nodes: [ThoughtGraphNode]) {
        self.nodes = nodes
        self.nodeIndex = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        guard !nodes.isEmpty else {
            layouts = []
            edges = []
            totalSize = .zero
            return
        }

        // ---- 1. Infer edges (or use explicit parentIDs) ----
        let computedEdges = inferEdges(from: nodes)
        self.edges = computedEdges

        // ---- 2. Group nodes by depth ----
        var depthGroups: [Int: [ThoughtGraphNode]] = [:]
        for node in nodes {
            depthGroups[node.depth, default: []].append(node)
        }
        let depths = depthGroups.keys.sorted()

        guard !depths.isEmpty else {
            layouts = []
            edges = []
            totalSize = .zero
            return
        }

        // ---- 3. Position nodes depth by depth ----
        var positionIndex: [String: CGPoint] = [:]
        var maxX: Double = -.infinity
        var minX: Double = .infinity
        var maxY: Double = -.infinity
        var minY: Double = .infinity

        for depth in depths {
            guard let depthNodes = depthGroups[depth] else { continue }
            let y = Double(depth) * (Self.nodeSize.height + Self.minVerticalGap)

            // ---- 3a. Compute desired x (center under average parent x) ----
            var desired: [(node: ThoughtGraphNode, desiredX: Double)] = depthNodes.map { node in
                let parentXs = node.parentIDs.compactMap { positionIndex[$0]?.x }
                if parentXs.isEmpty {
                    // Root node or node with parents not yet positioned — will
                    // be evenly spaced below.
                    return (node, 0)
                }
                let avgX = parentXs.reduce(0, +) / Double(parentXs.count)
                return (node, avgX)
            }

            // ---- 3b. Sort by desired x for stable sweep ----
            desired.sort { $0.desiredX < $1.desiredX }

            // ---- 3c. Sweep: enforce minimum horizontal gap ----
            var swept: [(node: ThoughtGraphNode, x: Double)] = []
            for item in desired {
                var x = item.desiredX
                if let last = swept.last {
                    let minAllowed = last.x + Self.nodeSize.width + Self.minHorizontalGap
                    if x < minAllowed {
                        x = minAllowed
                    }
                }
                swept.append((item.node, x))
            }

            // ---- 3d. Center the layer around x = 0 ----
            if let firstX = swept.first?.x, let lastX = swept.last?.x {
                let layerCenter = (firstX + lastX) / 2
                swept = swept.map { ($0.node, $0.x - layerCenter) }
            }

            // ---- 3e. Store positions and update bounding box ----
            for (node, x) in swept {
                positionIndex[node.id] = CGPoint(x: x, y: y)

                let halfW = Self.nodeSize.width / 2
                if x - halfW < minX { minX = x - halfW }
                if x + halfW > maxX { maxX = x + halfW }
                if y < minY { minY = y }
                if y + Self.nodeSize.height > maxY { maxY = y + Self.nodeSize.height }
            }
        }

        // ---- 4. Build layout array ----
        var layoutResults: [ThoughtGraphLayout] = []
        for node in nodes {
            guard let pos = positionIndex[node.id] else { continue }
            layoutResults.append(ThoughtGraphLayout(
                nodeID: node.id,
                x: pos.x,
                y: pos.y,
                width: Self.nodeSize.width,
                height: Self.nodeSize.height
            ))
        }
        self.layouts = layoutResults
        self.layoutIndex = Dictionary(uniqueKeysWithValues: layoutResults.map { ($0.nodeID, $0) })

        // ---- 5. Compute total graph bounds (with padding) ----
        let padding: Double = Self.nodeSize.height // generous padding
        if maxX.isFinite && minX.isFinite && maxY.isFinite && minY.isFinite {
            totalSize = CGSize(
                width: max(maxX - minX + padding * 2, 200),
                height: max(maxY - minY + padding * 2, 200)
            )
        } else {
            totalSize = .zero
        }
    }

    // MARK: - Edge Path

    /// Compute a curved edge path from a parent node's **bottom-center** to a
    /// child node's **top-center**.
    ///
    /// The curve uses a quadratic bezier with a gentle perpendicular bow,
    /// matching the organic aesthetic of `WikiGraphView`. The owning view
    /// is expected to stroke the path with a dashed style (since all edges
    /// in the current implementation are inferred).
    ///
    /// - Parameters:
    ///   - parentID: The node ID of the source (parent) node.
    ///   - childID:  The node ID of the destination (child) node.
    /// - Returns: A `Path` from the parent's bottom-center to the child's
    ///   top-center, or an empty path if either node is missing.
    func edgePath(from parentID: String, to childID: String) -> Path {
        guard let parentLayout = layoutIndex[parentID],
              let childLayout = layoutIndex[childID] else {
            return Path()
        }

        let start = CGPoint(
            x: parentLayout.x,
            y: parentLayout.y + parentLayout.height / 2
        )
        let end = CGPoint(
            x: childLayout.x,
            y: childLayout.y - childLayout.height / 2
        )

        // Build a gentle bezier bow, identical in spirit to WikiGraphView.
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = max(hypot(dx, dy), 1)
        let bow: CGFloat = min(len * 0.12, 26)
        let ctrl = CGPoint(x: mid.x - dy / len * bow, y: mid.y + dx / len * bow)

        var path = Path()
        path.move(to: start)
        path.addQuadCurve(to: end, control: ctrl)
        return path
    }

    // MARK: - Helpers

    /// Lookup the `ThoughtGraphLayout` for a given node ID.
    func layout(for nodeID: String) -> ThoughtGraphLayout? {
        layoutIndex[nodeID]
    }

    // MARK: - Static Convenience

    /// Convert an array of `ToolCallRecord` into a fully inferred and laid-out
    /// array of `ThoughtGraphNode`. Performs category-based dependency
    /// inference (search→read, read→patch/write, terminal→patch), parallel
    /// detection via overlapping execution windows, and depth assignment
    /// before layout.
    static func inferAndLayout(
        tools: [ToolCallRecord],
        canvasSize _: CGSize  // reserved for future canvas-relative sizing
    ) -> [ThoughtGraphNode] {
        var nodes = tools.map { ThoughtGraphNode.from(toolCall: $0) }
        guard nodes.count > 1 else {
            // Single node: it's just a root
            if var solo = nodes.first {
                solo.depth = 0
                nodes[0] = solo
            }
            return nodes
        }

        // ── Infer dependencies using category patterns + parallel detection ──
        nodes = Self.inferCategoryDependencies(nodes)

        // ── Build layout through a throwaway engine ──
        let engine = ThoughtGraphLayoutEngine()
        engine.layout(nodes: nodes)
        return nodes
    }

    // MARK: - Dependency Inference

    /// Infer parent→child edges from the given nodes.
    ///
    /// Strategy (in priority order):
    /// 1. If **any node has explicit `parentIDs`**, use those as-is. This
    ///    allows callers to pre-populate dependency data when available.
    /// 2. If **depth values are present** (max depth > 0), assume that tools
    ///    at depth N+1 depend on *all* tools at depth N. This is a coarse
    ///    but useful heuristic for typical agent reasoning chains.
    /// 3. If **no depth information is available** (all nodes at depth 0),
    ///    fall back to a **sequential chain** where each tool depends on the
    ///    previous one in array order.
    ///
    /// All edges are considered "inferred" and should be rendered with a
    /// dashed stroke in the visualization.
    private func inferEdges(from nodes: [ThoughtGraphNode]) -> [(from: String, to: String)] {
        // Strategy 1: explicit parentIDs
        let hasExplicit = nodes.contains { !$0.parentIDs.isEmpty }
        if hasExplicit {
            let validIDs = Set(nodes.map(\.id))
            var result: [(String, String)] = []
            for node in nodes {
                for pid in node.parentIDs where validIDs.contains(pid) {
                    result.append((pid, node.id))
                }
            }
            return result
        }

        // Group by depth
        var depthGroups: [Int: [ThoughtGraphNode]] = [:]
        for node in nodes {
            depthGroups[node.depth, default: []].append(node)
        }
        let maxDepth = depthGroups.keys.max() ?? 0

        // Strategy 2: depth-based inference.
        // Connect each child to a single representative parent via
        // proportional index mapping — an all-parents × all-children cross
        // product generates O(n²) edges that are each bezier-stroked per
        // frame. Positions aren't computed yet at this point, so "nearest"
        // is approximated by relative position within each depth layer.
        if maxDepth > 0 {
            var result: [(String, String)] = []
            for depth in 0 ..< maxDepth {
                guard let parents = depthGroups[depth],
                      let children = depthGroups[depth + 1] else { continue }
                for (i, child) in children.enumerated() {
                    let parentIdx = min(i * parents.count / children.count, parents.count - 1)
                    result.append((parents[parentIdx].id, child.id))
                }
            }
            return result
        }

        // Strategy 3: sequential chain
        var result: [(String, String)] = []
        for i in 0 ..< (nodes.count - 1) {
            result.append((nodes[i].id, nodes[i + 1].id))
        }
        return result
    }

    // MARK: - Category-Based Inference

    /// Tool category used for dependency inference and color coding.
    enum ToolCategory: String {
        case search  // search_files, web_search, grep, find
        case read    // read_file, cat, open
        case write   // write_file, create, save
        case patch   // patch, edit, replace, diff
        case terminal // terminal, shell, exec, bash, run
        case other   // everything else

        /// Classify a tool by its name.
        static func classify(name: String) -> ToolCategory {
            let lower = name.lowercased()
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
    }

    /// Infer dependencies using tool-category patterns (search→read→patch/write,
    /// terminal→patch) and detect parallel siblings via overlapping execution
    /// windows.
    ///
    /// ## Algorithm
    /// 1. Classify every node by tool name.
    /// 2. Walk the array in order (assumed chronological by start time).
    /// 3. A **search** node starts a new root chain at depth 0.
    /// 4. A **read** node depends on the most recent search at its depth.
    /// 5. A **write** or **patch** node depends on the most recent read at depth-1
    ///    (or search if no reads are present).
    /// 6. A **terminal** node depends on the most recent node before it (any category)
    ///    and produces a result that downstream patch nodes can consume.
    /// 7. **Parallel detection**: two nodes of the same category that start before
    ///    the previous one completes are siblings (same depth + same parents).
    private static func inferCategoryDependencies(_ nodes: [ThoughtGraphNode]) -> [ThoughtGraphNode] {
        var result = nodes

        // Build a mutable lookup of the most recent node ID at each depth, per category.
        var mostRecentByDepth: [Int: [ToolCategory: String]] = [:]

        for i in result.indices {
            let cat = ToolCategory.classify(name: result[i].name)

            switch cat {
            case .search:
                // Search nodes are roots (depth 0)
                result[i].depth = 0
                result[i].parentIDs = []
                mostRecentByDepth[0, default: [:]][cat] = result[i].id

            case .read:
                // Reads depend on the most recent search, or become roots
                if let searchID = mostRecentByDepth[0]?[.search] {
                    result[i].depth = 1
                    result[i].parentIDs = [searchID]
                } else {
                    result[i].depth = 0
                    result[i].parentIDs = []
                }
                mostRecentByDepth[result[i].depth, default: [:]][cat] = result[i].id

            case .write, .patch:
                // write/patch depend on the most recent read at depth 1,
                // or search if no reads exist, or become roots
                if let readID = mostRecentByDepth[1]?[.read] {
                    result[i].depth = 2
                    result[i].parentIDs = [readID]
                } else if let searchID = mostRecentByDepth[0]?[.search] {
                    result[i].depth = 1
                    result[i].parentIDs = [searchID]
                } else {
                    result[i].depth = 0
                    result[i].parentIDs = []
                }
                mostRecentByDepth[result[i].depth, default: [:]][cat] = result[i].id

            case .terminal:
                // Terminal nodes depend on whatever was most recent before them,
                // and act as a bridge: downstream patches can depend on terminals.
                let prevIdx = i > 0 ? i - 1 : 0
                if i > 0 {
                    result[i].depth = result[prevIdx].depth + 1
                    result[i].parentIDs = [result[prevIdx].id]
                } else {
                    result[i].depth = 0
                    result[i].parentIDs = []
                }
                mostRecentByDepth[result[i].depth, default: [:]][cat] = result[i].id

            case .other:
                // Others chain sequentially: depend on the immediately previous node
                if i > 0 {
                    result[i].depth = result[i - 1].depth + 1
                    result[i].parentIDs = [result[i - 1].id]
                } else {
                    result[i].depth = 0
                    result[i].parentIDs = []
                }
            }
        }

        // ── Parallel detection: nodes with overlapping execution windows ──
        // If two adjacent nodes at the same depth share the same parent(s)
        // and their execution windows overlap, they are siblings.
        for i in 1 ..< result.count {
            let prev = result[i - 1]
            var cur = result[i]

            // Only adjust if they could plausibly be siblings
            guard cur.depth == prev.depth,
                  cur.parentIDs == prev.parentIDs,
                  let curStart = cur.startedAt,
                  prev.startedAt != nil else { continue }

            // If cur started before prev completed, they overlap → siblings
            if let prevEnd = prev.completedAt {
                if curStart < prevEnd {
                    // Same depth, same parents = sibling
                    // No change needed; they're already at the same depth with same parents.
                    // Just ensure depth consistency.
                    cur.depth = prev.depth
                    result[i] = cur
                }
            }
        }

        return result
    }
}
