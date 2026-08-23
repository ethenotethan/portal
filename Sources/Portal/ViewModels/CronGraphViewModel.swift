import SwiftUI
import Combine

// MARK: - CronGraphViewModel

/// Drives the cron interflow graph surface: loads `cron.graph`, runs a small
/// synchronous force layout, and owns selection, hover, drag, zoom and pan.
///
/// Cron graphs are a handful of nodes (jobs + their sources / artifacts /
/// sinks), so the wiki graph's off-main-thread physics engine is overkill —
/// a synchronous settle plus a 30 Hz live tick keeps the code small and the
/// motion smooth. Tapping a node only *highlights* it: unlike the wiki graph
/// there is no reader to open, so this VM carries none of that coupling.
@MainActor
internal final class CronGraphViewModel: ObservableObject {

    internal struct SimNode: Identifiable {
        internal let id: String
        internal var position: CGPoint
        internal var velocity: CGVector = .zero
        internal var isDragging = false
        internal let kind: String
        internal let type: String
        internal let label: String
    }

    /// The silhouette drawn for a node kind. Shape — not color — is now the
    /// primary "what kind of thing is this" cue: once cron nodes were tinted by
    /// their category folder, color alone no longer told a job apart from a
    /// resource it touches. A round job, a triangular source, a database
    /// cylinder, a diamond sink, and a rounded-square service read at a glance
    /// regardless of hue.
    internal enum NodeGlyph {
        case circle, triangle, cylinder, diamond, cluster, roundedSquare
    }

    @Published internal private(set) var graph = CronGraph.empty {
        didSet { hulledCategoryFolders = Set(categoryHulls.map(\.key)) }
    }
    @Published internal var simNodes: [SimNode] = []
    @Published internal private(set) var simLinks: [(sourceIndex: Int, targetIndex: Int)] = []
    /// Edge type per link, aligned 1:1 with `simLinks` — drawn on the edge.
    @Published internal private(set) var simLinkTypes: [String] = []
    @Published internal var selectedNodeIndex: Int?
    @Published internal var hoveredNodeIndex: Int?
    /// Group scheme keys currently collapsed into a single super-node. Persists
    /// across reloads (stale keys are ignored) so a folded-away cluster stays
    /// folded when the graph refreshes.
    @Published internal private(set) var collapsedGroups: Set<String> = []
    @Published internal var zoom: CGFloat = 1.0
    @Published internal var panOffset: CGSize = .zero
    @Published internal private(set) var isLoading = false
    @Published internal private(set) var error: String?
    private var isRefreshing = false

    internal var canvasSize: CGSize = .zero
    internal private(set) var adjacency: [Set<Int>] = []
    /// Node indices sorted by Y — painter's order for the canvas.
    internal private(set) var drawOrder: [Int] = []

    // Physics — same feel as the wiki graph, tuned for small graphs.
    private var alpha: CGFloat = 1.0
    private let alphaDecay: CGFloat = 0.0228
    private let alphaMin: CGFloat = 0.002
    private let dragReheat: CGFloat = 0.2
    private let friction: CGFloat = 0.9
    private let springLength: CGFloat = 130
    private let springConstant: CGFloat = 0.01
    private let chargeConstant: CGFloat = 12000
    /// Pulls members of the same cluster (a scheme group or a cron category)
    /// toward their shared centroid. Without it, cluster-mates that don't link to
    /// each other are only pushed apart by charge repulsion, so they scatter and
    /// the hull drawn around them sprawls with nodes dangling on its edge. Charge
    /// repulsion still wins at close range, so members tighten without collapsing.
    private let cohesionConstant: CGFloat = 0.12
    private let centerPull: CGFloat = 0.0006
    private let maxVelocity: CGFloat = 30
    private let maxRepulsionForce: CGFloat = 500
    private let iterationsPerFrame = 2

    internal var simAlpha: CGFloat { alpha }
    internal var highlightAnchor: Int? { selectedNodeIndex ?? hoveredNodeIndex }

    // MARK: - Load

    internal func load(client: GatewayClient) async {
        isLoading = true
        error = nil
        do {
            graph = try await client.cronGraph()
            setupSimulation()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        isLoading = false
    }

    /// Refresh runtime health without scrambling a settled graph. A topology
    /// change still rebuilds the simulation, while health-only updates preserve
    /// positions, zoom, and the selected service inspector.
    internal func refreshRuntimeState(client: GatewayClient) async {
        guard !isRefreshing, !graph.isEmpty else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let updated = try await client.cronGraph()
            let topologyChanged = Self.topologySignature(graph) != Self.topologySignature(updated)
            graph = updated
            if topologyChanged { setupSimulation() }
        } catch {
            // Keep the last known graph visible. The manual Retry path remains
            // responsible for surfacing transport failures.
        }
    }

    private static func topologySignature(_ graph: CronGraph) -> [String] {
        let nodes = graph.nodes.map { "n:\($0.id):\($0.kind):\($0.type):\($0.label)" }
        let edges = graph.edges.map { "e:\($0.source):\($0.target):\($0.type)" }
        return (nodes + edges).sorted()
    }


    #if DEBUG
    /// Seed the raw graph directly, bypassing the gateway — tests exercise
    /// grouping and projection without a live `cron.graph` response.
    internal func setGraphForTesting(_ graph: CronGraph) {
        self.graph = graph
    }
    #endif

    // MARK: - Simulation setup

    internal func setupSimulation() {
        let effective = effectiveGraph()
        guard !effective.nodes.isEmpty else {
            simNodes = []; simLinks = []; simLinkTypes = []; adjacency = []; drawOrder = []
            return
        }
        let size = effectiveCanvasSize
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var rng = SystemRandomNumberGenerator()
        simNodes = effective.nodes.map { node in
            let angle = Double.random(in: 0...(2 * .pi), using: &rng)
            let dist = Double.random(in: 40...180, using: &rng)
            return SimNode(
                id: node.id,
                position: CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist),
                kind: node.kind, type: node.type, label: node.label
            )
        }
        rebuildTopology(from: effective)
        selectedNodeIndex = nil
        hoveredNodeIndex = nil
        alpha = 1.0
        settle()
    }

    /// Rebuild `simLinks` / `simLinkTypes` / `adjacency` from an edge set against
    /// the current `simNodes`. Shared by the fresh seed and the grouping rebuild,
    /// both of which lay down nodes first and then wire them.
    private func rebuildTopology(from effective: CronGraph) {
        let idToIndex = Dictionary(uniqueKeysWithValues: simNodes.enumerated().map { ($1.id, $0) })
        var links: [(sourceIndex: Int, targetIndex: Int)] = []
        var types: [String] = []
        for edge in effective.edges {
            guard let si = idToIndex[edge.source], let ti = idToIndex[edge.target] else { continue }
            links.append((si, ti))
            types.append(edge.type)
        }
        simLinks = links
        simLinkTypes = types
        adjacency = Array(repeating: Set<Int>(), count: simNodes.count)
        for (si, ti) in links {
            adjacency[si].insert(ti)
            adjacency[ti].insert(si)
        }
    }

    /// The canvas size, or a nominal fallback when the graph is laid out before
    /// the canvas has reported its real bounds.
    private var effectiveCanvasSize: CGSize {
        canvasSize == .zero ? CGSize(width: 640, height: 460) : canvasSize
    }

    /// Relax the freshly-seeded layout in place so the graph appears already
    /// settled instead of visibly exploding apart. Cheap for small graphs.
    private func settle() {
        guard simNodes.count > 1 else { recomputeDrawOrder(); return }
        var a: CGFloat = 1.0
        let steps = min(300, max(80, simNodes.count * 6))
        for _ in 0..<steps {
            step(alpha: a)
            a += (alphaMin - a) * alphaDecay
            if a < 0.02 { break }
        }
        alpha = alphaMin
        recomputeDrawOrder()
        fitToView()
    }

    // MARK: - Tick / integration

    internal func tick() {
        let anyDragging = simNodes.contains { $0.isDragging }
        guard alpha > alphaMin || anyDragging else { return }
        step(alpha: alpha)
        recomputeDrawOrder()
        if anyDragging {
            alpha = max(alpha, dragReheat)
        } else {
            alpha += (alphaMin - alpha) * alphaDecay
        }
    }

    private func step(alpha: CGFloat) {
        guard simNodes.count > 1 else { return }
        let size = effectiveCanvasSize
        let clusters = clusterIndexSets()
        for _ in 0..<iterationsPerFrame {
            var forces = Array(repeating: CGVector.zero, count: simNodes.count)
            // Repulsion — every pair pushes apart (O(n²); fine at this scale).
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                for j in (i + 1)..<simNodes.count {
                    let dx = simNodes[i].position.x - simNodes[j].position.x
                    let dy = simNodes[i].position.y - simNodes[j].position.y
                    let distSq = dx * dx + dy * dy
                    guard distSq > 0.01 else { continue }
                    let force = min(chargeConstant / distSq, maxRepulsionForce)
                    let dist = sqrt(distSq)
                    let fx = dx / dist * force
                    let fy = dy / dist * force
                    forces[i].dx += fx; forces[i].dy += fy
                    forces[j].dx -= fx; forces[j].dy -= fy
                }
            }
            // Springs — pull linked nodes toward the rest length.
            for (si, ti) in simLinks {
                let dx = simNodes[ti].position.x - simNodes[si].position.x
                let dy = simNodes[ti].position.y - simNodes[si].position.y
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > 0 else { continue }
                let force = (dist - springLength) * springConstant
                let fx = dx / dist * force
                let fy = dy / dist * force
                forces[si].dx += fx; forces[si].dy += fy
                forces[ti].dx -= fx; forces[ti].dy -= fy
            }
            // Cohesion — pull each cluster's members toward their centroid so
            // grouped nodes settle together and the hull around them stays tight.
            for members in clusters {
                var cx: CGFloat = 0, cy: CGFloat = 0
                for i in members { cx += simNodes[i].position.x; cy += simNodes[i].position.y }
                cx /= CGFloat(members.count); cy /= CGFloat(members.count)
                for i in members where !simNodes[i].isDragging {
                    forces[i].dx += (cx - simNodes[i].position.x) * cohesionConstant
                    forces[i].dy += (cy - simNodes[i].position.y) * cohesionConstant
                }
            }
            // Centering + integration.
            let meanX = simNodes.reduce(0) { $0 + $1.position.x } / CGFloat(simNodes.count)
            let meanY = simNodes.reduce(0) { $0 + $1.position.y } / CGFloat(simNodes.count)
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                forces[i].dx += (size.width / 2 - meanX) * centerPull
                forces[i].dy += (size.height / 2 - meanY) * centerPull
                var v = simNodes[i].velocity
                v.dx = (v.dx + forces[i].dx * alpha) * friction
                v.dy = (v.dy + forces[i].dy * alpha) * friction
                let speed = sqrt(v.dx * v.dx + v.dy * v.dy)
                if speed > maxVelocity {
                    let scale = maxVelocity / speed
                    v.dx *= scale; v.dy *= scale
                }
                simNodes[i].velocity = v
                simNodes[i].position.x += v.dx
                simNodes[i].position.y += v.dy
            }
        }
    }

    private func recomputeDrawOrder() {
        drawOrder = simNodes.indices.sorted { simNodes[$0].position.y < simNodes[$1].position.y }
    }

    /// The index sets the cohesion force pulls together — one per multi-member
    /// cluster among the *present* sim nodes. Crons cluster by category folder,
    /// resource/sink nodes by ref scheme; this mirrors exactly what draws a hull
    /// (super-nodes and collapsed-away members never appear here). Recomputed each
    /// step so membership tracks expand/collapse without extra bookkeeping.
    private func clusterIndexSets() -> [[Int]] {
        var byKey: [String: [Int]] = [:]
        for (index, node) in simNodes.enumerated() {
            switch node.kind {
            case "cron":
                if let folder = categoryFolder(forLabel: node.label) {
                    byKey["cat:\(folder)", default: []].append(index)
                }
            case "group":
                continue
            default:
                byKey["scheme:\(node.type)", default: []].append(index)
            }
        }
        return byKey.values.filter { $0.count >= 2 }.map { $0 }
    }

    // MARK: - Framing

    internal func fitToView() {
        guard simNodes.count > 1 else { return }
        let size = effectiveCanvasSize
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for node in simNodes {
            minX = min(minX, node.position.x); maxX = max(maxX, node.position.x)
            minY = min(minY, node.position.y); maxY = max(maxY, node.position.y)
        }
        let graphW = max(maxX - minX, 1), graphH = max(maxY - minY, 1)
        let margin: CGFloat = 90
        let fitZoom = min((size.width - margin * 2) / graphW, (size.height - margin * 2) / graphH)
        let newZoom = max(0.4, min(1.6, fitZoom))
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        zoom = newZoom
        panOffset = CGSize(width: size.width / 2 - cx * newZoom, height: size.height / 2 - cy * newZoom)
    }

    internal func resetView() {
        fitToView()
        alpha = max(alpha, dragReheat)
    }

    /// Zoom by `factor` while keeping the graph point under `point` (a canvas
    /// coordinate) fixed on screen, so pinching or scroll-zoom homes in on what
    /// the cursor is over rather than the origin. Mirrors the wiki graph's
    /// `zoomAtPoint`; clamps to a usable range so the graph can't invert or
    /// vanish. Pan compensates by the zoom delta about that point.
    internal func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let oldZoom = zoom
        let newZoom = max(0.3, min(5.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        panOffset.width += point.x * (oldZoom - newZoom)
        panOffset.height += point.y * (oldZoom - newZoom)
        zoom = newZoom
    }

    /// Zoom about the canvas center — the anchor for the +/- buttons, which have
    /// no cursor to home on.
    internal func zoomAtCenter(_ factor: CGFloat) {
        let size = effectiveCanvasSize
        zoomAtPoint(factor: factor, around: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    // MARK: - Interaction

    internal func hitTest(point: CGPoint) -> Int? {
        let mx = (point.x - panOffset.width) / zoom
        let my = (point.y - panOffset.height) / zoom
        for (index, node) in simNodes.enumerated().reversed() {
            let r = radius(forKind: node.kind) + 5
            if abs(node.position.x - mx) < r && abs(node.position.y - my) < r { return index }
        }
        return nil
    }

    internal func startDragging(index: Int, at point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = true
        simNodes[index].velocity = .zero
        alpha = max(alpha, dragReheat)
    }

    internal func dragNode(index: Int, to point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].position = CGPoint(
            x: (point.x - panOffset.width) / zoom,
            y: (point.y - panOffset.height) / zoom
        )
        recomputeDrawOrder()
        alpha = max(alpha, dragReheat)
    }

    internal func stopDragging(index: Int) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = false
    }

    internal func updateHover(at point: CGPoint) {
        let idx = hitTest(point: point)
        if idx != hoveredNodeIndex { hoveredNodeIndex = idx }
    }

    internal func clearHover() {
        if hoveredNodeIndex != nil { hoveredNodeIndex = nil }
    }

    internal func handleTap(at point: CGPoint) {
        guard let idx = hitTest(point: point) else {
            selectedNodeIndex = nil
            return
        }
        // A collapsed cluster's super-node expands on tap rather than selecting —
        // there's no single ref behind it to open, so the useful action is to
        // unfold it back into its members.
        if let key = groupKey(fromSuperNodeID: simNodes[idx].id) {
            toggleGroupCollapsed(key)
            return
        }
        selectedNodeIndex = (selectedNodeIndex == idx) ? nil : idx
    }

    /// Select the node whose id matches `id`, highlighting it and dimming the
    /// rest exactly as a tap would. No-op if no node carries that id. Drives the
    /// job card's tappable dataflow chips and the expanded view's neighbor
    /// navigation — both key off the shared `CronGraphNode.id`.
    internal func selectNode(withID id: String) {
        guard let idx = simNodes.firstIndex(where: { $0.id == id }) else { return }
        selectedNodeIndex = idx
    }

    // MARK: - Grouping

    /// The scheme groups present in the current graph (≥2 members each), for the
    /// hull boundaries and the collapse toggles. Recomputed from the raw graph so
    /// it reflects every member regardless of what's currently collapsed.
    internal var groups: [CronNodeGroup] {
        CronNodeGrouping.groups(from: graph)
    }

    /// Whether a scheme's cluster is currently folded into its super-node.
    internal func isGroupCollapsed(_ key: String) -> Bool {
        collapsedGroups.contains(key)
    }

    /// The scheme key behind a super-node id, or nil for a real node — how a tap
    /// or the sim tells a collapsed cluster apart from an ordinary ref.
    internal func groupKey(fromSuperNodeID id: String) -> String? {
        let prefix = "group:"
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }

    /// Fold a scheme's members into one super-node (or unfold them), then relax
    /// the layout around the change. Members that survive keep their positions so
    /// only the affected cluster moves; the super-node seeds at its members'
    /// centroid and reheats so the tick animates the settle rather than snapping.
    internal func toggleGroupCollapsed(_ key: String) {
        if collapsedGroups.contains(key) {
            collapsedGroups.remove(key)
        } else {
            collapsedGroups.insert(key)
        }
        applyGrouping()
    }

    /// The graph as the canvas should draw it given `collapsedGroups`: each
    /// collapsed scheme's members are dropped and replaced by one `group`
    /// super-node, and every edge touching a folded member is rerouted to that
    /// super-node (self-loops and duplicates dropped). Uncollapsed — returns the
    /// raw graph untouched.
    internal func effectiveGraph() -> CronGraph {
        guard !collapsedGroups.isEmpty else { return graph }
        let groupsByKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
        var remap: [String: String] = [:]
        var superNodes: [CronGraphNode] = []
        for key in collapsedGroups.sorted() {
            guard let group = groupsByKey[key] else { continue }
            for memberID in group.memberIDs { remap[memberID] = group.superNodeID }
            superNodes.append(CronGraphNode(
                id: group.superNodeID, kind: "group", type: key,
                label: "\(key) · \(group.memberIDs.count)", description: "",
                schedule: nil, enabled: true, usesLLM: false, lastStatus: nil, deliver: nil
            ))
        }
        guard !superNodes.isEmpty else { return graph }
        let keptNodes = graph.nodes.filter { remap[$0.id] == nil }
        var seen: Set<String> = []
        var edges: [CronGraphEdge] = []
        for edge in graph.edges {
            let source = remap[edge.source] ?? edge.source
            let target = remap[edge.target] ?? edge.target
            guard source != target else { continue }
            guard seen.insert("\(source)->\(target):\(edge.type)").inserted else { continue }
            edges.append(CronGraphEdge(source: source, target: target, type: edge.type))
        }
        return CronGraph(nodes: keptNodes + superNodes, edges: edges)
    }

    /// Rebuild the simulation for the current collapse state while preserving the
    /// positions of nodes that persist, so a toggle animates from where things
    /// were instead of re-scrambling the whole graph.
    private func applyGrouping() {
        let priorPos = Dictionary(simNodes.map { ($0.id, $0.position) }, uniquingKeysWith: { first, _ in first })
        let effective = effectiveGraph()
        guard !effective.nodes.isEmpty else {
            simNodes = []; simLinks = []; simLinkTypes = []; adjacency = []; drawOrder = []
            return
        }
        let size = effectiveCanvasSize
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let groupsByKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.key, $0) })
        var rng = SystemRandomNumberGenerator()
        simNodes = effective.nodes.map { node in
            let position = seedPosition(
                for: node, priorPos: priorPos, center: center, groupsByKey: groupsByKey, rng: &rng
            )
            return SimNode(id: node.id, position: position, kind: node.kind, type: node.type, label: node.label)
        }
        rebuildTopology(from: effective)
        selectedNodeIndex = nil
        hoveredNodeIndex = nil
        recomputeDrawOrder()
        alpha = 1.0
    }

    /// Where a node starts after a grouping change: an unchanged node stays put; a
    /// fresh super-node lands at its members' centroid; a member reappearing on
    /// expand pops out from where its super-node sat, jittered so the cluster
    /// fans apart instead of stacking.
    private func seedPosition(
        for node: CronGraphNode,
        priorPos: [String: CGPoint],
        center: CGPoint,
        groupsByKey: [String: CronNodeGroup],
        rng: inout SystemRandomNumberGenerator
    ) -> CGPoint {
        if let existing = priorPos[node.id] { return existing }
        if node.kind == "group", let group = groupsByKey[node.type] {
            let points = group.memberIDs.compactMap { priorPos[$0] }
            guard !points.isEmpty else { return center }
            return CGPoint(x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
                           y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count))
        }
        if let superPos = priorPos["group:\(node.type)"] {
            let angle = Double.random(in: 0...(2 * .pi), using: &rng)
            let dist = Double.random(in: 20...45, using: &rng)
            return CGPoint(x: superPos.x + cos(angle) * dist, y: superPos.y + sin(angle) * dist)
        }
        return center
    }

    // MARK: - Selection helpers

    internal func isNodeConnectedToSelection(_ index: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        if index == anchor { return true }
        return adjacency.indices.contains(anchor) && adjacency[anchor].contains(index)
    }

    internal func linkIsConnectedToSelection(_ source: Int, _ target: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        return source == anchor || target == anchor
    }

    internal func selectedNodeNeighbors() -> [Int] {
        guard let sel = selectedNodeIndex, adjacency.indices.contains(sel) else { return [] }
        return Array(adjacency[sel])
    }

    internal var selectedNode: CronGraphNode? {
        guard let sel = selectedNodeIndex, simNodes.indices.contains(sel) else { return nil }
        let id = simNodes[sel].id
        return graph.nodes.first { $0.id == id }
    }

    internal func serviceHealth(forNodeID id: String) -> CronServiceHealth? {
        graph.nodes.first { $0.id == id }?.health
    }

    // MARK: - Appearance

    internal func color(forKind kind: String) -> Color {
        switch kind {
        case "cron": return Color(hex: "7c9cff") ?? .blue
        case "source": return Color(hex: "5cb85c") ?? .green
        case "artifact": return Color(hex: "e8a838") ?? .orange
        case "sink": return Color(hex: "ff6b9d") ?? .pink
        case "service": return Color(hex: "2fc4b6") ?? .teal
        case "group": return Color(hex: "b18cff") ?? .purple
        default: return Color(hex: "aaaaaa") ?? .gray
        }
    }

    /// The fill for one node. Sources, artifacts, and sinks use the fixed kind
    /// palette; cron nodes are tinted by their top-level category folder so jobs
    /// filed together share a hue. A cron with no category keeps the base blue.
    ///
    /// The folder comes from the label because that's the job name, and a cron
    /// carries its category in its name (`life/training/run`) — the same
    /// convention `CronCategory` reads everywhere else.
    internal func nodeColor(kind: String, label: String) -> Color {
        guard kind == "cron", let folder = categoryFolder(forLabel: label) else {
            return color(forKind: kind)
        }
        return categoryColor(forFolder: folder)
    }

    /// The tint for a cron category folder — a stable per-folder hue shared by the
    /// node fill, its legend swatch, and the hull drawn around the category, so
    /// the three read as one grouping.
    internal func categoryColor(forFolder folder: String) -> Color {
        Color(hue: stableHue(for: folder), saturation: 0.52, brightness: 0.98)
    }

    /// The fill for a sim node including cluster super-nodes, which are tinted by
    /// their scheme key (carried in `type`) rather than the generic group color so
    /// a folded `wiki` cluster keeps wiki's hue.
    internal func nodeColor(kind: String, type: String, label: String) -> Color {
        guard kind == "group" else { return nodeColor(kind: kind, label: label) }
        return groupColor(forKey: type)
    }

    /// A stable per-scheme tint shared by a group's hull boundary, its super-node,
    /// and its collapse toggle, so the three read as one cluster. Distinct schemes
    /// of the same kind still separate by hue.
    internal func groupColor(forKey key: String) -> Color {
        Color(hue: stableHue(for: key), saturation: 0.5, brightness: 0.96)
    }

    /// The top-level category folder of a cron's name, or nil when ungrouped.
    private func categoryFolder(forLabel label: String) -> String? {
        CronCategory.split(name: label).path.first
    }

    /// A stable hue in `0..<1` for a folder name, independent of process launch.
    ///
    /// `String.hashValue` is per-process randomized, so the same folder would
    /// tint differently every run — a hand-rolled FNV-1a keeps `life` the same
    /// hue across launches and across the two view models that draw crons.
    private func stableHue(for key: String) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Double(hash % 3600) / 3600.0
    }

    /// The distinct cron category folders present in the graph, each with its
    /// tint, sorted for a stable legend. Empty when no cron carries a category.
    internal var categoryLegend: [(name: String, color: Color)] {
        var seen: Set<String> = []
        var out: [(name: String, color: Color)] = []
        for node in graph.nodes where node.kind == "cron" {
            guard let folder = categoryFolder(forLabel: node.label),
                  seen.insert(folder).inserted else { continue }
            out.append((folder, nodeColor(kind: "cron", label: node.label)))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Cron category folders with ≥2 jobs, each with its member ids and tint —
    /// the source for the soft hull drawn around jobs filed together. Unlike the
    /// scheme `groups` these are a visual grouping only: no collapse, no
    /// super-node, no edge rerouting. Sorted by descending member count then name
    /// so the draw order is stable across reloads.
    internal var categoryHulls: [(key: String, memberIDs: [String], color: Color)] {
        var membersByFolder: [String: [String]] = [:]
        for node in graph.nodes where node.kind == "cron" {
            guard let folder = categoryFolder(forLabel: node.label) else { continue }
            membersByFolder[folder, default: []].append(node.id)
        }
        return membersByFolder
            .compactMap { folder, ids -> (key: String, memberIDs: [String], color: Color)? in
                guard ids.count >= 2 else { return nil }
                return (key: folder, memberIDs: ids, color: categoryColor(forFolder: folder))
            }
            .sorted { $0.memberIDs.count != $1.memberIDs.count ? $0.memberIDs.count > $1.memberIDs.count : $0.key < $1.key }
    }

    /// Category folders the canvas draws a hull label for, cached off `categoryHulls`
    /// whenever the graph changes. `drawLabels` asks per node per frame, and
    /// `categoryHulls` walks every node to build its answer.
    internal private(set) var hulledCategoryFolders: Set<String> = []

    /// The text drawn beside a node on the canvas.
    ///
    /// A cron inside a category hull is already sitting under that folder's name
    /// in 9pt caps, so repeating it in the node label says `projection` twice and
    /// pushes the part that actually identifies the job off the edge of the
    /// screen: `projection / x402 wiki projection` under a `PROJECTION` hull reads
    /// as `x402 wiki projection`. Deeper levels survive (`indexing/wiki/x402` →
    /// `wiki/x402`) because the hull only names the top folder.
    ///
    /// A cron whose folder has no hull — an ungrouped job, or the only job in its
    /// folder — keeps its full name: there the label is the one place the
    /// category appears at all. Same rule the category tree uses for its rows,
    /// which is why it lives in `CronCategory` rather than here.
    internal func displayLabel(forKind kind: String, label: String) -> String {
        guard kind == "cron",
              let folder = categoryFolder(forLabel: label),
              hulledCategoryFolders.contains(folder) else { return label }
        return CronCategory.name(label, strippingLeadingFolder: folder)
    }

    internal func radius(forKind kind: String) -> CGFloat {
        switch kind {
        case "group": return 14
        case "cron", "service": return 9
        case "artifact": return 7
        default: return 6
        }
    }

    /// The silhouette for a node kind, in `legend` order: cron jobs are circles
    /// (the actor that runs), sources are triangles (an external input feeding
    /// in), artifacts are database cylinders (a written/persisted store), and
    /// sinks are diamonds (a terminal side-effect target). Drives both the
    /// canvas node bodies and the legend/detail swatches so the key teaches the
    /// exact shapes on the graph. Services are rounded squares — a running box
    /// (process/container), the one node kind that is an actor like a cron but
    /// stays up instead of firing on a schedule.
    internal func glyph(forKind kind: String) -> NodeGlyph {
        switch kind {
        case "cron": return .circle
        case "source": return .triangle
        case "artifact": return .cylinder
        case "sink": return .diamond
        case "service": return .roundedSquare
        case "group": return .cluster
        default: return .circle
        }
    }

    /// The structural edge types (reads/writes/feeds) read in the accent blue;
    /// side-effect edges (telegram/pr/…) pick up their sink's warm hue so a
    /// terminal action is visually distinct from a data hop.
    internal func edgeColor(forType type: String) -> Color {
        switch type {
        case "reads", "writes", "feeds": return Color(hex: "8a8aff") ?? .accentColor
        // `hosts` is containment, not dataflow: the service on the source end
        // RUNS the resource on the target end (a Postgres container hosting the
        // tables crons read and write). It gets the muted service hue rather
        // than the dataflow violet so it reads as infrastructure behind the
        // flow instead of another hop in it. Without this case it would fall
        // through to the warm sink tint and be mistaken for a delivery.
        case "hosts": return color(forKind: "service")
        default: return color(forKind: "sink")
        }
    }

    /// True when an edge type is containment rather than dataflow, and should be
    /// drawn as a dashed line without an arrowhead — nothing *moves* along a
    /// `hosts` edge, so a directional arrow would misdescribe it.
    internal func edgeIsContainment(_ type: String) -> Bool { type == "hosts" }

    /// The edge types present in the current graph, each with a display label and
    /// its tint, in dataflow order (reads → writes → feeds → hosts → delivers).
    /// Drives the edge key so the arrow colors on the canvas read without
    /// per-edge text. Any non-structural type (a side-effect scheme like
    /// telegram/pr) folds into a single "Delivers" entry, since they all share
    /// the warm sink hue. `hosts` is listed explicitly after the dataflow types:
    /// it is structural but is containment rather than flow, so it must not fold
    /// into "Delivers".
    internal var edgeLegend: [(type: String, label: String, color: Color)] {
        let present = Set(simLinkTypes)
        var out: [(type: String, label: String, color: Color)] = []
        for (type, label) in [("reads", "Reads"), ("writes", "Writes"), ("feeds", "Feeds"),
                              ("hosts", "Hosts")]
        where present.contains(type) {
            out.append((type: type, label: label, color: edgeColor(forType: type)))
        }
        let structural: Set<String> = ["reads", "writes", "feeds", "hosts"]
        if present.contains(where: { !structural.contains($0) }) {
            out.append((type: "deliver", label: "Delivers", color: edgeColor(forType: "deliver")))
        }
        return out
    }

    /// Legend rows for the node kinds, in dataflow order.
    internal static let legend: [(kind: String, label: String)] = [
        ("cron", "Cron job"),
        ("source", "Source"),
        ("artifact", "Artifact"),
        ("sink", "Sink"),
        ("service", "Service"),
    ]
}
