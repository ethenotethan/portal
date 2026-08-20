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

    @Published internal private(set) var graph = CronGraph.empty
    @Published internal var simNodes: [SimNode] = []
    @Published internal private(set) var simLinks: [(sourceIndex: Int, targetIndex: Int)] = []
    /// Edge type per link, aligned 1:1 with `simLinks` — drawn on the edge.
    @Published internal private(set) var simLinkTypes: [String] = []
    @Published internal var selectedNodeIndex: Int?
    @Published internal var hoveredNodeIndex: Int?
    @Published internal var zoom: CGFloat = 1.0
    @Published internal var panOffset: CGSize = .zero
    @Published internal private(set) var isLoading = false
    @Published internal private(set) var error: String?

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

    // MARK: - Simulation setup

    internal func setupSimulation() {
        guard !graph.nodes.isEmpty else {
            simNodes = []; simLinks = []; simLinkTypes = []; adjacency = []; drawOrder = []
            return
        }
        let size = effectiveCanvasSize
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var rng = SystemRandomNumberGenerator()
        simNodes = graph.nodes.map { node in
            let angle = Double.random(in: 0...(2 * .pi), using: &rng)
            let dist = Double.random(in: 40...180, using: &rng)
            return SimNode(
                id: node.id,
                position: CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist),
                kind: node.kind, type: node.type, label: node.label
            )
        }
        let idToIndex = Dictionary(uniqueKeysWithValues: simNodes.enumerated().map { ($1.id, $0) })
        var links: [(sourceIndex: Int, targetIndex: Int)] = []
        var types: [String] = []
        for edge in graph.edges {
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
        selectedNodeIndex = nil
        hoveredNodeIndex = nil
        alpha = 1.0
        settle()
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
        if let idx = hitTest(point: point) {
            selectedNodeIndex = (selectedNodeIndex == idx) ? nil : idx
        } else {
            selectedNodeIndex = nil
        }
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

    // MARK: - Appearance

    internal func color(forKind kind: String) -> Color {
        switch kind {
        case "cron": return Color(hex: "7c9cff") ?? .blue
        case "source": return Color(hex: "5cb85c") ?? .green
        case "artifact": return Color(hex: "e8a838") ?? .orange
        case "sink": return Color(hex: "ff6b9d") ?? .pink
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
        return Color(hue: stableHue(for: folder), saturation: 0.52, brightness: 0.98)
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

    internal func radius(forKind kind: String) -> CGFloat {
        switch kind {
        case "cron": return 9
        case "artifact": return 7
        default: return 6
        }
    }

    /// The structural edge types (reads/writes/feeds) read in the accent blue;
    /// side-effect edges (telegram/pr/…) pick up their sink's warm hue so a
    /// terminal action is visually distinct from a data hop.
    internal func edgeColor(forType type: String) -> Color {
        switch type {
        case "reads", "writes", "feeds": return Color(hex: "8a8aff") ?? .accentColor
        default: return color(forKind: "sink")
        }
    }

    /// Legend rows for the four node kinds, in dataflow order.
    internal static let legend: [(kind: String, label: String)] = [
        ("cron", "Cron job"),
        ("source", "Source"),
        ("artifact", "Artifact"),
        ("sink", "Sink"),
    ]
}
