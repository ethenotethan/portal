import Foundation

/// JSON contract for ```graph fenced blocks — node-link diagrams (dependency
/// graphs, service topologies, social networks) laid out force-directed:
/// ```json
/// {
///   "title": "optional",
///   "directed": true,
///   "nodes": [
///     {"id": "api", "label": "API Server", "group": "backend", "size": 2}
///   ],
///   "edges": [
///     {"from": "api", "to": "db", "label": "reads"}
///   ]
/// }
/// ```
/// `label` defaults to the id; `group` colors nodes categorically; `size`
/// (0.5–3) scales a node's radius; `directed` defaults to true (arrowheads).
struct NetworkGraphSpec: Decodable {
    struct Node: Decodable, Identifiable {
        let id: String
        let label: String
        let group: String?
        let size: Double

        private enum CodingKeys: String, CodingKey {
            case id, label, group, size
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? id
            group = try c.decodeIfPresent(String.self, forKey: .group)
            let raw = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
            size = min(3, max(0.5, raw))
        }

        init(id: String, label: String, group: String? = nil, size: Double = 1) {
            self.id = id
            self.label = label
            self.group = group
            self.size = size
        }
    }

    struct Edge: Decodable {
        let from: String
        let to: String
        let label: String?
    }

    let title: String?
    let directed: Bool
    let nodes: [Node]
    let edges: [Edge]

    private enum CodingKeys: String, CodingKey {
        case title, directed, nodes, edges
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        directed = try c.decodeIfPresent(Bool.self, forKey: .directed) ?? true
        let rawNodes = try c.decode([Node].self, forKey: .nodes)
        let rawEdges = try c.decodeIfPresent([Edge].self, forKey: .edges) ?? []

        // Dedupe nodes by id (models repeat them); drop edges whose
        // endpoints don't exist rather than failing the whole graph.
        var seen = Set<String>()
        nodes = rawNodes.filter { seen.insert($0.id).inserted }
        let ids = seen
        edges = rawEdges.filter { ids.contains($0.from) && ids.contains($0.to) }
    }

    /// Distinct groups in first-appearance order (drives the legend).
    var groups: [String] {
        var seen = Set<String>()
        return nodes.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    static func parse(_ json: String) -> NetworkGraphSpec? {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(NetworkGraphSpec.self, from: data),
              !spec.nodes.isEmpty else { return nil }
        return spec
    }
}

// MARK: - Static force layout

/// One-shot force-directed layout: runs the same charge/spring/center
/// simulation as the wiki graph, but to convergence at parse time instead of
/// ticking live — a chat block should settle once and hold still.
enum NetworkGraphLayout {

    struct PlacedNode: Identifiable {
        let node: NetworkGraphSpec.Node
        let position: CGPoint
        var id: String { node.id }
    }

    struct Result {
        let placed: [PlacedNode]
        let size: CGSize
        let positions: [String: CGPoint]
    }

    /// Deterministic layout for `spec` targeting roughly `width` points.
    /// Seeded ring start (stable across re-renders of the same spec) +
    /// 300 settle iterations, then normalized into a padded bounding box.
    static func layout(_ spec: NetworkGraphSpec, width: CGFloat) -> Result {
        let n = spec.nodes.count
        let indexOf = Dictionary(uniqueKeysWithValues: spec.nodes.enumerated().map { ($1.id, $0) })
        let links: [(Int, Int)] = spec.edges.compactMap {
            guard let s = indexOf[$0.from], let t = indexOf[$0.to] else { return nil }
            return (s, t)
        }

        // Seeded ring start: radius grows with node count so big graphs
        // don't start collapsed.
        let ringRadius = max(80, Double(n) * 14)
        var xs = [Double](repeating: 0, count: n)
        var ys = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let angle = 2 * .pi * Double(i) / Double(max(1, n))
            xs[i] = ringRadius * cos(angle)
            ys[i] = ringRadius * sin(angle)
        }

        // Force constants scaled to node count; tuned against the wiki
        // simulation's feel but biased to converge fast.
        let charge = 6000.0
        let springLength = 110.0
        let spring = 0.06
        let centerPull = 0.02
        var alpha = 1.0

        guard n > 1 else {
            let placed = spec.nodes.map { PlacedNode(node: $0, position: CGPoint(x: width / 2, y: 90)) }
            return Result(placed: placed, size: CGSize(width: width, height: 180),
                          positions: Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.position) }))
        }

        for _ in 0..<300 {
            var fx = [Double](repeating: 0, count: n)
            var fy = [Double](repeating: 0, count: n)
            // Pairwise repulsion.
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let dx = xs[i] - xs[j], dy = ys[i] - ys[j]
                    let distSq = max(0.01, dx * dx + dy * dy)
                    let force = min(charge / distSq, 40)
                    let dist = distSq.squareRoot()
                    fx[i] += dx / dist * force; fy[i] += dy / dist * force
                    fx[j] -= dx / dist * force; fy[j] -= dy / dist * force
                }
            }
            // Spring attraction along edges.
            for (s, t) in links {
                let dx = xs[t] - xs[s], dy = ys[t] - ys[s]
                let dist = max(0.01, (dx * dx + dy * dy).squareRoot())
                let force = (dist - springLength) * spring
                fx[s] += dx / dist * force; fy[s] += dy / dist * force
                fx[t] -= dx / dist * force; fy[t] -= dy / dist * force
            }
            // Centering.
            let meanX = xs.reduce(0, +) / Double(n)
            let meanY = ys.reduce(0, +) / Double(n)
            for i in 0..<n {
                fx[i] -= meanX * centerPull
                fy[i] -= meanY * centerPull
            }
            for i in 0..<n {
                xs[i] += fx[i] * alpha
                ys[i] += fy[i] * alpha
            }
            alpha *= 0.985
            if alpha < 0.02 { break }
        }

        // Normalize into a padded box; scale down (never up) to fit width.
        let pad = 56.0
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        let rawW = max(1, maxX - minX)
        let rawH = max(1, maxY - minY)
        let scale = min(1, (Double(width) - pad * 2) / rawW)
        let boxW = Double(width)
        let boxH = rawH * scale + pad * 2
        let offsetX = (boxW - rawW * scale) / 2

        let placed = spec.nodes.enumerated().map { i, node in
            PlacedNode(node: node, position: CGPoint(
                x: (xs[i] - minX) * scale + offsetX,
                y: (ys[i] - minY) * scale + pad
            ))
        }
        return Result(
            placed: placed,
            size: CGSize(width: boxW, height: boxH),
            positions: Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.position) })
        )
    }
}
