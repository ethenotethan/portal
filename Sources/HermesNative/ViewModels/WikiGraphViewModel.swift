import SwiftUI
import Combine
import os.log

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "WikiGraphViewModel")

/// Force-directed graph simulation adapted from rayfix/ForceDirectedGraph.
/// Uses a simple spring-charge model with centering force.
@MainActor
final class WikiGraphViewModel: ObservableObject {

    // MARK: - Published

    @Published var graph: WikiGraph = .empty
    @Published var selectedPage: WikiPage?
    @Published var showPageDetail = false
    @Published var isLoading = false
    @Published var error: String?

    // MARK: - Simulation State

    struct SimNode: Identifiable {
        let id: String
        var position: CGPoint
        var velocity: CGVector = .zero
        var isDragging = false
        let type: String
        let label: String
    }

    var simNodes: [SimNode] = []
    var simLinks: [(sourceIndex: Int, targetIndex: Int)] = []

    // Simulation parameters (tuned for ~20-50 nodes)
    private let friction: CGFloat = 0.92
    private let springLength: CGFloat = 120
    private let springConstant: CGFloat = 0.008
    private let chargeConstant: CGFloat = 8000
    private let centerPull: CGFloat = 0.0005
    private let iterationsPerFrame = 5

    // View transforms
    @Published var zoom: CGFloat = 1.0
    @Published var panOffset: CGSize = .zero
    var canvasSize: CGSize = .zero

    // MARK: - Color mapping

    func color(for type: String) -> Color {
        switch type {
        case "entity": return Color(hex: "7c7cff")!    // purple
        case "concept": return Color(hex: "5cb85c")!   // green
        case "comparison": return Color(hex: "e8a838")! // orange
        case "query": return Color(hex: "ff6b9d")!     // pink
        case "raw": return Color(hex: "888888")!       // gray
        default: return Color(hex: "aaaaaa")!
        }
    }

    func nodeRadius(for type: String) -> CGFloat {
        type == "entity" ? 7 : 5
    }

    // MARK: - Gateway

    func load(client: GatewayClient) async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let newGraph = try await client.wikiScan()
            self.graph = newGraph
            setupSimulation()
        } catch {
            log.error("wiki.scan failed: \(error.localizedDescription)")
            self.error = error.localizedDescription
        }
    }

    func loadPage(client: GatewayClient, path: String) async -> WikiPageContent? {
        do {
            return try await client.wikiPage(path: path)
        } catch {
            log.error("wiki.page failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Simulation Setup

    func setupSimulation() {
        guard !graph.pages.isEmpty else { return }

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        var rng = SystemRandomNumberGenerator()

        simNodes = graph.pages.map { page in
            SimNode(
                id: page.id,
                position: CGPoint(
                    x: center.x + CGFloat(Int.random(in: -150...150, using: &rng)),
                    y: center.y + CGFloat(Int.random(in: -150...150, using: &rng))
                ),
                type: page.type,
                label: page.title
            )
        }

        let idToIndex = Dictionary(uniqueKeysWithValues: simNodes.enumerated().map { ($1.id, $0) })
        simLinks = graph.links.compactMap { link -> (Int, Int)? in
            guard let si = idToIndex[link.source],
                  let ti = idToIndex[link.target] else { return nil }
            return (si, ti)
        }
    }

    // MARK: - Simulation Step

    func tick() {
        guard simNodes.count > 1 else { return }

        let positions = simNodes.map { $0.position }
        var velocities = simNodes.map { $0.velocity }

        for _ in 0..<iterationsPerFrame {
            var forces = Array(repeating: CGVector.zero, count: positions.count)

            // Repulsion (charge)
            for i in 0..<positions.count {
                guard !simNodes[i].isDragging else { continue }
                for j in (i+1)..<positions.count {
                    let dx = positions[i].x - positions[j].x
                    let dy = positions[i].y - positions[j].y
                    let distSq = dx*dx + dy*dy
                    guard distSq > 1 else { continue }
                    let force = chargeConstant / distSq
                    let dist = sqrt(distSq)
                    let fx = (dx / dist) * force
                    let fy = (dy / dist) * force
                    forces[i].dx += fx
                    forces[i].dy += fy
                    forces[j].dx -= fx
                    forces[j].dy -= fy
                }
            }

            // Spring forces (links)
            for (si, ti) in simLinks {
                let dx = positions[ti].x - positions[si].x
                let dy = positions[ti].y - positions[si].y
                let dist = sqrt(dx*dx + dy*dy)
                guard dist > 0 else { continue }
                let force = (dist - springLength) * springConstant
                let fx = (dx / dist) * force
                let fy = (dy / dist) * force
                forces[si].dx += fx
                forces[si].dy += fy
                forces[ti].dx -= fx
                forces[ti].dy -= fy
            }

            // Centering force
            let meanX = positions.reduce(0) { $0 + $1.x } / CGFloat(positions.count)
            let meanY = positions.reduce(0) { $0 + $1.y } / CGFloat(positions.count)
            let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            for i in 0..<positions.count {
                guard !simNodes[i].isDragging else { continue }
                forces[i].dx += (center.x - meanX) * centerPull
                forces[i].dy += (center.y - meanY) * centerPull
            }

            // Integrate
            for i in 0..<simNodes.count {
                guard !simNodes[i].isDragging else { continue }
                var v = velocities[i]
                v.dx = (v.dx + forces[i].dx) * friction
                v.dy = (v.dy + forces[i].dy) * friction
                velocities[i] = v
                simNodes[i].position.x += v.dx
                simNodes[i].position.y += v.dy
                simNodes[i].velocity = v
            }
        }
    }

    // MARK: - Interaction

    func hitTest(point: CGPoint) -> Int? {
        // Convert view point to model space
        let mx = (point.width - panOffset.width) / zoom
        let my = (point.height - panOffset.height) / zoom
        let modelPoint = CGPoint(x: mx, y: my)

        for (index, node) in simNodes.enumerated().reversed() {
            let r = nodeRadius(for: node.type) + 4 // hit padding
            if abs(node.position.x - modelPoint.x) < r && abs(node.position.y - modelPoint.y) < r {
                return index
            }
        }
        return nil
    }

    func startDragging(index: Int, at point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = true
        simNodes[index].velocity = .zero
    }

    func dragNode(index: Int, to point: CGPoint) {
        guard simNodes.indices.contains(index) else { return }
        let mx = (point.x - panOffset.width) / zoom
        let my = (point.y - panOffset.height) / zoom
        simNodes[index].position = CGPoint(x: mx, y: my)
    }

    func stopDragging(index: Int) {
        guard simNodes.indices.contains(index) else { return }
        simNodes[index].isDragging = false
    }

    func handleTap(at point: CGPoint) {
        if let index = hitTest(point: point) {
            let pageID = simNodes[index].id
            if let page = graph.pages.first(where: { $0.id == pageID }) {
                selectedPage = page
                showPageDetail = true
            }
        }
    }

    func zoomAtPoint(factor: CGFloat, around point: CGPoint) {
        let oldZoom = zoom
        zoom = max(0.3, min(5.0, zoom * factor))
        // Adjust pan so the zoom centers on the point
        panOffset.width -= point.x * (1/oldZoom - 1/zoom)
        panOffset.height -= point.y * (1/oldZoom - 1/zoom)
    }
}

// MARK: - Helpers

extension CGPoint {
    var width: CGFloat { x }
    var height: CGFloat { y }
}

extension CGVector {
    static let zero = CGVector(dx: 0, dy: 0)
}

