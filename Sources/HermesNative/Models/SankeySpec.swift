import Foundation

/// JSON contract for ```sankey fenced blocks — branching flow diagrams
/// (budget allocation, token flows, traffic funnels):
/// ```json
/// {
///   "title": "Q2 Budget",
///   "links": [
///     {"from": "Revenue", "to": "Engineering", "value": 400},
///     {"from": "Revenue", "to": "Marketing", "value": 150},
///     {"from": "Engineering", "to": "Salaries", "value": 320}
///   ]
/// }
/// ```
/// Nodes are implicit from link endpoints. Optional `nodes` array adds
/// per-node groups for coloring: [{"name": "Revenue", "group": "income"}].
struct SankeySpec {
    struct Link {
        let from: String
        let to: String
        let value: Double
    }

    let title: String?
    let links: [Link]
    /// Node name → group (for coloring); empty when unspecified.
    let groups: [String: String]

    /// Distinct group labels in first-appearance order over node order.
    var groupNames: [String] {
        var seen = Set<String>()
        return nodeOrder.compactMap { groups[$0] }.filter { seen.insert($0).inserted }
    }

    /// All node names: sources before targets, in link order.
    var nodeOrder: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for link in links where seen.insert(link.from).inserted {
            order.append(link.from)
        }
        for link in links where seen.insert(link.to).inserted {
            order.append(link.to)
        }
        return order
    }

    static func parse(_ json: String) -> SankeySpec? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawLinks = obj["links"] as? [[String: Any]] else { return nil }

        let links: [Link] = rawLinks.compactMap { raw in
            guard let from = (raw["from"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let to = (raw["to"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !from.isEmpty, !to.isEmpty, from != to else { return nil }
            let value = (raw["value"] as? NSNumber)?.doubleValue ?? 0
            guard value > 0 else { return nil }
            return Link(from: from, to: to, value: value)
        }
        guard !links.isEmpty else { return nil }

        var groups: [String: String] = [:]
        for node in (obj["nodes"] as? [[String: Any]]) ?? [] {
            if let name = node["name"] as? String, let group = node["group"] as? String {
                groups[name] = group
            }
        }
        return SankeySpec(title: obj["title"] as? String, links: links, groups: groups)
    }
}

// MARK: - Layout

/// Column-and-ribbon layout for sankey rendering. Deterministic and pure —
/// computed once per spec, testable without a view.
enum SankeyLayout {

    struct Node: Identifiable {
        let name: String
        let column: Int
        /// Total flow through the node (max of in/out — bar height ∝ this).
        let throughput: Double
        /// Vertical span in normalized [0,1] column coordinates.
        var y0: Double = 0
        var y1: Double = 0
        var id: String { name }
    }

    struct Ribbon: Identifiable {
        let from: String
        let to: String
        let value: Double
        /// Normalized vertical spans on the source's right edge and the
        /// target's left edge.
        var sourceY0: Double = 0
        var sourceY1: Double = 0
        var targetY0: Double = 0
        var targetY1: Double = 0
        var id: String { "\(from)→\(to)" }
    }

    struct Result {
        let nodes: [Node]
        let ribbons: [Ribbon]
        let columnCount: Int
    }

    /// Cycle-safe longest-path column assignment, then greedy vertical
    /// packing in link order. Nodes in a cycle break at the revisit (the
    /// offending link renders column-adjacent rather than exploding).
    static func layout(_ spec: SankeySpec) -> Result {
        let order = spec.nodeOrder
        guard !order.isEmpty else { return Result(nodes: [], ribbons: [], columnCount: 0) }

        // Column = longest path from any pure source, computed iteratively
        // with a visit cap for cycle safety.
        var column: [String: Int] = [:]
        for name in order { column[name] = 0 }
        var changed = true
        var passes = 0
        while changed && passes < order.count + 1 {
            changed = false
            passes += 1
            for link in spec.links {
                let needed = (column[link.from] ?? 0) + 1
                if (column[link.to] ?? 0) < needed {
                    column[link.to] = needed
                    changed = true
                }
            }
        }
        let columnCount = (column.values.max() ?? 0) + 1

        // Throughput per node.
        var inflow: [String: Double] = [:]
        var outflow: [String: Double] = [:]
        for link in spec.links {
            outflow[link.from, default: 0] += link.value
            inflow[link.to, default: 0] += link.value
        }

        var nodes: [Node] = order.map { name in
            Node(name: name, column: column[name] ?? 0,
                 throughput: max(inflow[name] ?? 0, outflow[name] ?? 0))
        }

        // Vertical packing per column: nodes in appearance order, spans
        // proportional to throughput, uniform gaps. Scale is GLOBAL (the
        // busiest column's total) so bar heights compare across columns.
        let gap = 0.02
        var columnTotals: [Int: Double] = [:]
        for node in nodes { columnTotals[node.column, default: 0] += node.throughput }
        let maxTotal = columnTotals.values.max() ?? 1

        for columnIndex in 0..<columnCount {
            let members = nodes.indices.filter { nodes[$0].column == columnIndex }
            let total = members.reduce(0.0) { $0 + nodes[$1].throughput }
            let gapsTotal = gap * Double(max(0, members.count - 1))
            let scale = (1.0 - gapsTotal) / maxTotal
            // Center the column vertically.
            let contentHeight = total * scale + gapsTotal
            var y = (1.0 - contentHeight) / 2
            for index in members {
                let height = nodes[index].throughput * scale
                nodes[index].y0 = y
                nodes[index].y1 = y + height
                y += height + gap
            }
        }

        // Ribbon spans: stack outgoing links down each source's edge and
        // incoming links down each target's edge, in link order.
        let nodeByName = Dictionary(uniqueKeysWithValues: nodes.map { ($0.name, $0) })
        var outCursor: [String: Double] = [:]
        var inCursor: [String: Double] = [:]
        let scale = (1.0 - gap * 0) / maxTotal  // same global scale, gaps excluded per-edge

        var ribbons: [Ribbon] = spec.links.map {
            Ribbon(from: $0.from, to: $0.to, value: $0.value)
        }
        for index in ribbons.indices {
            let ribbon = ribbons[index]
            guard let source = nodeByName[ribbon.from], let target = nodeByName[ribbon.to] else { continue }
            let height = ribbon.value * scale
            let sourceStart = source.y0 + (outCursor[ribbon.from] ?? 0)
            ribbons[index].sourceY0 = sourceStart
            ribbons[index].sourceY1 = sourceStart + height
            outCursor[ribbon.from, default: 0] += height
            let targetStart = target.y0 + (inCursor[ribbon.to] ?? 0)
            ribbons[index].targetY0 = targetStart
            ribbons[index].targetY1 = targetStart + height
            inCursor[ribbon.to, default: 0] += height
        }

        return Result(nodes: nodes, ribbons: ribbons, columnCount: columnCount)
    }
}
