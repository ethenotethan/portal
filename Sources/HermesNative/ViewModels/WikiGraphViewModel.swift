import SwiftUI
import Combine
import os.log
import simd

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "WikiGraphViewModel")

@MainActor
final class WikiGraphViewModel: ObservableObject {

    @Published var graph: WikiGraph = .empty
    @Published var selectedPage: WikiPage?
    @Published var showPageDetail = false
    @Published var selectedNodeIndex: Int?
    @Published var hoveredNodeIndex: Int?

    var selectedNodeTitle: String? {
        guard let idx = selectedNodeIndex, simNodes.indices.contains(idx) else { return nil }
        return simNodes[idx].label
    }
    @Published var isLoading = false
    @Published var error: String?
    @Published var searchQuery = "" {
        didSet { updateFilteredNodes() }
    }

    /// Node indices that match the current search query. Empty = show all.
    var filteredNodeIndices: Set<Int> = []
    private var cachedQuery: String = ""

    var isFiltering: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    private func updateFilteredNodes() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard cachedQuery != q else { return }
        cachedQuery = q
        if q.isEmpty {
            filteredNodeIndices.removeAll()
            return
        }
        let terms = q.split(separator: " ").map(String.init)
        filteredNodeIndices = Set(simNodes.indices.filter { idx in
            guard simNodes.indices.contains(idx) else { return false }
            let node = simNodes[idx]
            let haystack = "\(node.label.lowercased()) \(node.type.lowercased())"
            return terms.allSatisfy { haystack.contains($0) }
        })
    }

    struct SimNode: Identifiable {
        let id: String
        var position: CGPoint
        var velocity: CGVector = .zero
        var position3D: SIMD3<Float> = .zero
        var velocity3D: SIMD3<Float> = .zero
        var isDragging = false
        let type: String
        let label: String
    }

    @Published var simNodes: [SimNode] = []
    @Published var simLinks: [(sourceIndex: Int, targetIndex: Int)] = []
    private(set) var degrees: [Int] = []

    private let friction: CGFloat = 0.92
    private let springLength: CGFloat = 120
    private let springConstant: CGFloat = 0.008
    private let chargeConstant: CGFloat = 8000
    private let centerPull: CGFloat = 0.0005
    private let iterationsPerFrame = 2
    private let maxVelocity: CGFloat = 30
    private let maxRepulsionForce: CGFloat = 500

    private var alpha: CGFloat = 1.0
    private let alphaDecay: CGFloat = 0.0228
    private let alphaMin: CGFloat = 0.002
    private let dragReheat: CGFloat = 0.15
    var simAlpha: CGFloat { alpha }
    var is3D = false

    private let springLength3D: Float = 160
    private let centerPull3D: Float = 0.0008
    private let maxVelocity3D: Float = 30

    @Published var zoom: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    var canvasSize: CGSize = .zero

    func color(for type: String) -> Color {
        switch type {
        case "entity": return Color(hex: "7c7cff")!
        case "concept": return Color(hex: "5cb85c")!
        case "comparison": return Color(hex: "e8a838")!
        case "query": return Color(hex: "ff6b9d")!
        case "raw": return Color(hex: "888888")!
        default: return Color(hex: "aaaaaa")!
        }
    }

    func nodeRadius(for type: String) -> CGFloat { type == "entity" ? 7 : 5 }

    func nodeRadius(at index: Int) -> CGFloat {
        guard simNodes.indices.contains(index) else { return 5 }
        let base = nodeRadius(for: simNodes[index].type)
        let degree = degrees.indices.contains(index) ? degrees[index] : 0
        let bonus = min(CGFloat(degree) * 0.9, 10)
        return base + log2(CGFloat(degree) + 1) * 1.4 + bonus * 0.15
    }

    @Published var selectedWikiPath: String?
    @Published var availableWikis: [String] = []

    func load(client: GatewayClient, wiki: String? = nil) async {
        isLoading = true; error = nil; defer { isLoading = false }
        do {
            let newGraph = try await client.wikiScan(wiki: wiki)
            self.graph = newGraph
            if canvasSize != .zero { setupSimulation() }
        } catch {
            log.error("wiki.scan failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func discoverWikis(client: GatewayClient) async {
        do { let wikis = try await client.wikiList(); self.availableWikis = wikis.map { $0.name } }
        catch { log.warning("wiki.list failed: \(error.localizedDescription)") }
    }

    func loadPage(client: GatewayClient, path: String, wiki: String? = nil) async -> WikiPageContent? {
        do { return try await client.wikiPage(path: path, wiki: wiki) }
        catch { log.error("wiki.page failed: \(error.localizedDescription)"); return nil }
    }

    func setupSimulation() {
        guard canvasSize != .zero, !graph.pages.isEmpty else { return }
        if is3D { setup3D() } else { setup2D() }
    }

    private func setup2D() {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        var rng = SystemRandomNumberGenerator()
        simNodes = graph.pages.map { page in
            let angle = Double.random(in: 0...(2 * .pi), using: &rng)
            let dist = Double.random(in: 50...200, using: &rng)
            return SimNode(id: page.id, position: CGPoint(x: center.x + cos(angle) * dist, y: center.y + sin(angle) * dist), type: page.type, label: page.title)
        }
        finishSetup()
    }

    private func setup3D() {
        var rng = SystemRandomNumberGenerator()
        simNodes = graph.pages.map { page in
            let phi = Float.random(in: 0...(2 * .pi), using: &rng)
            let theta = Float.random(in: (-Float.pi / 3)...(Float.pi / 3), using: &rng)
            let r = Float.random(in: 60...180, using: &rng)
            return SimNode(id: page.id, position: .zero, position3D: SIMD3(r * cos(theta) * cos(phi), r * cos(theta) * sin(phi), r * sin(theta)), type: page.type, label: page.title)
        }
        finishSetup()
    }

    private func finishSetup() {
        var seenIds = Set<String>()
        simNodes = simNodes.filter { node in guard !seenIds.contains(node.id) else { return false }; seenIds.insert(node.id); return true }
        let idToIndex = Dictionary(uniqueKeysWithValues: simNodes.enumerated().map { ($1.id, $0) })
        simLinks = graph.links.compactMap { link -> (Int, Int)? in
            guard let si = idToIndex[link.source], let ti = idToIndex[link.target] else { return nil }
            return (si, ti)
        }
        degrees = Array(repeating: 0, count: simNodes.count)
        for (si, ti) in simLinks { if degrees.indices.contains(si) { degrees[si] += 1 }; if degrees.indices.contains(ti) { degrees[ti] += 1 } }
        alpha = 1.0
        updateFilteredNodes()
    }

    func tick() { if is3D { tick3D() } else { tick2D() } }

    private func tick2D() {
        guard canvasSize != .zero, simNodes.count > 1 else { return }
        let anyDragging = simNodes.contains { $0.isDragging }
        guard alpha > alphaMin || anyDragging else { return }
        for _ in 0..<iterationsPerFrame {
            var forces = Array(repeating: CGVector.zero, count: simNodes.count)
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                for j in (i + 1)..<simNodes.count {
                    let dx = simNodes[i].position.x - simNodes[j].position.x
                    let dy = simNodes[i].position.y - simNodes[j].position.y
                    let distSq = dx * dx + dy * dy
                    guard distSq > 0.01 else { continue }
                    let rawForce = chargeConstant / distSq
                    let force = min(rawForce, maxRepulsionForce)
                    let dist = sqrt(distSq)
                    let fx = (dx / dist) * force; let fy = (dy / dist) * force
                    forces[i].dx += fx; forces[i].dy += fy
                    forces[j].dx -= fx; forces[j].dy -= fy
                }
            }
            for (si, ti) in simLinks {
                let dx = simNodes[ti].position.x - simNodes[si].position.x
                let dy = simNodes[ti].position.y - simNodes[si].position.y
                let dist = sqrt(dx * dx + dy * dy)
                guard dist > 0 else { continue }
                let force = (dist - springLength) * springConstant
                let fx = (dx / dist) * force; let fy = (dy / dist) * force
                forces[si].dx += fx; forces[si].dy += fy
                forces[ti].dx -= fx; forces[ti].dy -= fy
            }
            let meanX = simNodes.reduce(0) { $0 + $1.position.x } / CGFloat(simNodes.count)
            let meanY = simNodes.reduce(0) { $0 + $1.position.y } / CGFloat(simNodes.count)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                forces[i].dx += (center.x - meanX) * centerPull
                forces[i].dy += (center.y - meanY) * centerPull
            }
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                var v = simNodes[i].velocity
                v.dx = (v.dx + forces[i].dx * alpha) * friction
                v.dy = (v.dy + forces[i].dy * alpha) * friction
                let speed = sqrt(v.dx * v.dx + v.dy * v.dy)
                if speed > maxVelocity { let scale = maxVelocity / speed; v.dx *= scale; v.dy *= scale }
                simNodes[i].velocity = v
                simNodes[i].position.x += v.dx; simNodes[i].position.y += v.dy
            }
        }
        if anyDragging { alpha = max(alpha, dragReheat) } else { alpha += (alphaMin - alpha) * alphaDecay }
    }

    private func tick3D() {
        guard simNodes.count > 1 else { return }
        let anyDragging = simNodes.contains { $0.isDragging }
        guard alpha > alphaMin || anyDragging else { return }
        let charge: Float = Float(chargeConstant)
        let maxForce: Float = Float(maxRepulsionForce)
        let springK: Float = Float(springConstant)
        for _ in 0..<iterationsPerFrame {
            var forces = Array(repeating: SIMD3<Float>.zero, count: simNodes.count)
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                for j in (i + 1)..<simNodes.count {
                    let d = simNodes[i].position3D - simNodes[j].position3D
                    let distSq = simd_length_squared(d)
                    guard distSq > 0.01 else { continue }
                    let raw = charge / distSq
                    let f = min(raw, maxForce)
                    let dir = d / sqrt(distSq)
                    forces[i] += dir * f; forces[j] -= dir * f
                }
            }
            for (si, ti) in simLinks {
                let d = simNodes[ti].position3D - simNodes[si].position3D
                let dist = simd_length(d)
                guard dist > 0 else { continue }
                let f = (dist - springLength3D) * springK
                let dir = d / dist
                forces[si] += dir * f; forces[ti] -= dir * f
            }
            var mean = SIMD3<Float>.zero
            for n in simNodes { mean += n.position3D }
            mean /= Float(simNodes.count)
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                forces[i] -= mean * centerPull3D
            }
            let fAlpha = Float(CGFloat(alpha))
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                var v = simNodes[i].velocity3D
                v = (v + forces[i] * fAlpha) * Float(friction)
                let speed = simd_length(v)
                if speed > maxVelocity3D { v *= maxVelocity3D / speed }
                simNodes[i].velocity3D = v
                simNodes[i].position3D += v
            }
        }
        if anyDragging { alpha = max(alpha, dragReheat) } else { alpha += (alphaMin - alpha) * alphaDecay }
    }

    func hitTest(point: CGPoint) -> Int? {
        let mx = (point.width - panOffset.width) / zoom
        let my = (point.height - panOffset.height) / zoom
        let modelPoint = CGPoint(x: mx, y: my)
        for (index, node) in simNodes.enumerated().reversed() {
            let r = nodeRadius(for: node.type) + 4
            if abs(node.position.x - modelPoint.x) < r && abs(node.position.y - modelPoint.y) < r { return index }
        }
        return nil
    }

    func startDragging(index: Int, at point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = true; simNodes[index].velocity = .zero
        alpha = max(alpha, dragReheat)
    }

    func dragNode(index: Int, to point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        let mx = (point.x - panOffset.width) / zoom
        let my = (point.y - panOffset.height) / zoom
        simNodes[index].position = CGPoint(x: mx, y: my)
        alpha = max(alpha, dragReheat)
    }

    func stopDragging(index: Int) { guard simNodes.indices.contains(index) else { return }; simNodes[index].isDragging = false }
    func updateHover(at point: CGPoint) { let idx = hitTest(point: CGPoint(x: point.x, y: point.y)); if idx != hoveredNodeIndex { hoveredNodeIndex = idx } }
    func clearHover() { if hoveredNodeIndex != nil { hoveredNodeIndex = nil } }
    var highlightAnchor: Int? { selectedNodeIndex ?? hoveredNodeIndex }

    func handleTap(at point: CGPoint) {
        if let index = hitTest(point: point) {
            if selectedNodeIndex == index { if let page = graph.pages.first(where: { $0.id == simNodes[index].id }) { selectedPage = page; showPageDetail = true } }
            else { selectedNodeIndex = index }
        } else { selectedNodeIndex = nil }
    }

    func deselectNode() { selectedNodeIndex = nil }

    func selectedNodeNeighbors() -> [Int] {
        guard let sel = selectedNodeIndex else { return [] }
        var result = Set<Int>()
        for (si, ti) in simLinks { if si == sel { result.insert(ti) }; if ti == sel { result.insert(si) } }
        return Array(result)
    }

    private func neighbors(of anchor: Int) -> Set<Int> {
        var result = Set<Int>()
        for (si, ti) in simLinks { if si == anchor { result.insert(ti) }; if ti == anchor { result.insert(si) } }
        return result
    }

    func isNodeConnectedToSelection(_ index: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        if index == anchor { return true }
        return neighbors(of: anchor).contains(index)
    }

    func linkIsConnectedToSelection(_ source: Int, _ target: Int) -> Bool {
        guard let anchor = highlightAnchor else { return true }
        return source == anchor || target == anchor
    }

    func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        guard factor.isFinite, factor > 0 else { return }
        let oldZoom = zoom; let newZoom = max(0.3, min(5.0, oldZoom * factor))
        guard newZoom != oldZoom else { return }
        panOffset.width += point.x * (oldZoom - newZoom)
        panOffset.height += point.y * (oldZoom - newZoom)
        zoom = newZoom
    }

    func resetView() { panOffset = .zero; zoom = 1.0 }
}

extension CGPoint { var width: CGFloat { x }; var height: CGFloat { y } }
extension CGVector { static let zero = CGVector(dx: 0, dy: 0) }
