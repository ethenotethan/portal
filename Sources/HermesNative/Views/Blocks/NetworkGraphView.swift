import SwiftUI

/// Renders a ```graph block as a force-directed node-link diagram. Layout is
/// computed once at parse time (static, deterministic) — a chat block should
/// settle and hold still, unlike the live wiki graph. Edges draw in a Canvas;
/// nodes are SwiftUI views so they get hover/tap for the detail readout.
struct NetworkGraphView: View {
    let json: String
    let isStreaming: Bool

    var body: some View {
        if let spec = NetworkGraphSpec.parse(json) {
            GraphCard(spec: spec)
        } else if Self.looksLikeMermaid(json) {
            // Models sometimes put mermaid `graph TD` syntax in a ```graph
            // fence. That's a diagram, not our JSON — route it to mermaid.
            MermaidDiagramView(mermaidCode: json, isStreaming: isStreaming)
        } else if isStreaming {
            EmptyView()
        } else {
            GraphErrorNote(source: json)
        }
    }

    /// Mermaid flowchart smell: starts with a direction header instead of {.
    static func looksLikeMermaid(_ s: String) -> Bool {
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24).lowercased()
        return head.hasPrefix("graph ") || head.hasPrefix("flowchart ")
            || head.hasPrefix("td") || head.hasPrefix("lr")
    }
}

// MARK: - Card

private struct GraphCard: View {
    let spec: NetworkGraphSpec
    @State private var selectedNodeID: String?
    /// Groups hidden via legend chips.
    @State private var hiddenGroups: Set<String> = []

    /// Categorical palette — same validated slots as NativeChartView
    /// (dark column, CVD-safe adjacent pairs on Theme.surface).
    private static let palette: [Color] = [
        "#3987e5", "#008300", "#d55181", "#c98500",
        "#199e70", "#d95926", "#9085e9", "#e66767",
    ].compactMap { Color(hex: $0) }

    private var groupColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: spec.groups.enumerated().map { index, group in
            (group, Self.palette[index % Self.palette.count])
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }
            GraphCanvas(
                spec: spec,
                groupColors: groupColors,
                hiddenGroups: hiddenGroups,
                selectedNodeID: $selectedNodeID
            )
            if !spec.groups.isEmpty {
                legendChips
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private var legendChips: some View {
        HStack(spacing: 6) {
            ForEach(spec.groups, id: \.self) { group in
                let hidden = hiddenGroups.contains(group)
                HStack(spacing: 5) {
                    Circle()
                        .fill(groupColors[group] ?? Theme.accent)
                        .frame(width: 8, height: 8)
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(hidden ? Theme.tertiary : Theme.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surfaceHover.opacity(hidden ? 0.3 : 0.6), in: Capsule())
                .opacity(hidden ? 0.5 : 1)
                .contentShape(Capsule())
                .onTapGesture {
                    if hidden { hiddenGroups.remove(group) } else { hiddenGroups.insert(group) }
                }
                .help(hidden ? "Show \(group)" : "Hide \(group)")
            }
        }
    }
}

// MARK: - Canvas

private struct GraphCanvas: View {
    let spec: NetworkGraphSpec
    let groupColors: [String: Color]
    let hiddenGroups: Set<String>
    @Binding var selectedNodeID: String?

    /// Node connectivity for the selection highlight: neighbors stay lit,
    /// the rest dim.
    private func neighbors(of id: String) -> Set<String> {
        var result: Set<String> = [id]
        for edge in spec.edges {
            if edge.from == id { result.insert(edge.to) }
            if edge.to == id { result.insert(edge.from) }
        }
        return result
    }

    var body: some View {
        GeometryReader { geo in
            let layout = NetworkGraphLayout.layout(spec, width: geo.size.width)
            let visible = visibleNodeIDs(layout)
            let lit = selectedNodeID.map(neighbors(of:))

            ZStack(alignment: .topLeading) {
                edgeCanvas(layout: layout, visible: visible, lit: lit)
                ForEach(layout.placed) { placed in
                    if visible.contains(placed.id) {
                        nodeView(placed, lit: lit)
                            .position(placed.position)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedNodeID = nil }
        }
        .frame(height: graphHeight)
    }

    /// Height comes from the deterministic layout at a nominal width —
    /// stable across the container's width jitter (never derive a
    /// representable-style height from live geometry).
    private var graphHeight: CGFloat {
        NetworkGraphLayout.layout(spec, width: 600).size.height
    }

    private func visibleNodeIDs(_ layout: NetworkGraphLayout.Result) -> Set<String> {
        Set(layout.placed.compactMap { placed in
            if let group = placed.node.group, hiddenGroups.contains(group) { return nil }
            return placed.id
        })
    }

    private func edgeCanvas(layout: NetworkGraphLayout.Result, visible: Set<String>, lit: Set<String>?) -> some View {
        Canvas { context, _ in
            for edge in spec.edges {
                guard visible.contains(edge.from), visible.contains(edge.to),
                      let from = layout.positions[edge.from],
                      let to = layout.positions[edge.to] else { continue }
                let isLit = lit == nil || (lit!.contains(edge.from) && lit!.contains(edge.to))
                let color = Theme.tertiary.opacity(isLit ? 0.75 : 0.18)

                var path = Path()
                path.move(to: from)
                path.addLine(to: to)
                context.stroke(path, with: .color(color), lineWidth: 1.2)

                if spec.directed {
                    drawArrowhead(context: context, from: from, to: to, color: color)
                }
                if let label = edge.label, isLit {
                    let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                    context.draw(
                        Text(label).font(.system(size: 9)).foregroundStyle(Theme.tertiary),
                        at: mid
                    )
                }
            }
        }
    }

    /// Arrowhead at the target end, inset by the node radius so it touches
    /// the circle's rim, not its center.
    private func drawArrowhead(context: GraphicsContext, from: CGPoint, to: CGPoint, color: Color) {
        let dx = to.x - from.x, dy = to.y - from.y
        let dist = max(0.01, sqrt(dx * dx + dy * dy))
        let ux = dx / dist, uy = dy / dist
        let nodeRadius: CGFloat = 14
        let tip = CGPoint(x: to.x - ux * nodeRadius, y: to.y - uy * nodeRadius)
        let back = CGPoint(x: tip.x - ux * 7, y: tip.y - uy * 7)
        let perp = CGPoint(x: -uy * 3.5, y: ux * 3.5)

        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: back.x + perp.x, y: back.y + perp.y))
        arrow.addLine(to: CGPoint(x: back.x - perp.x, y: back.y - perp.y))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    private func nodeView(_ placed: NetworkGraphLayout.PlacedNode, lit: Set<String>?) -> some View {
        let node = placed.node
        let color = node.group.flatMap { groupColors[$0] } ?? Theme.accent
        let isLit = lit == nil || lit!.contains(node.id)
        let isSelected = selectedNodeID == node.id
        let radius = 11 * node.size

        return VStack(spacing: 3) {
            Circle()
                .fill(color.opacity(isLit ? 1 : 0.25))
                .frame(width: radius * 2, height: radius * 2)
                .overlay(
                    Circle().stroke(
                        isSelected ? Theme.primary : Theme.surface,
                        lineWidth: isSelected ? 2 : 1.5
                    )
                )
            Text(node.label)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isLit ? Theme.primary : Theme.tertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedNodeID = isSelected ? nil : node.id
        }
        .help(node.group.map { "\(node.label) — \($0)" } ?? node.label)
    }
}

// MARK: - Error note

private struct GraphErrorNote: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't parse graph block")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            Text(source)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
