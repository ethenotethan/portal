import SwiftUI

/// Renders a ```sankey block: node bars in topological columns, cubic flow
/// ribbons with thickness ∝ value. Canvas + native text only (PDF-safe).
/// Click a node to highlight its flows; click background to clear.
struct SankeyBlockView: View {
    let json: String
    let isStreaming: Bool

    var body: some View {
        if let spec = SankeySpec.parse(json) {
            SankeyCard(spec: spec)
        } else if isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't parse sankey block")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct SankeyCard: View {
    let spec: SankeySpec
    @State private var selectedNode: String?

    /// Shared categorical palette (chart/graph/map parity).
    private static let palette: [Color] = [
        "#3987e5", "#008300", "#d55181", "#c98500",
        "#199e70", "#d95926", "#9085e9", "#e66767",
    ].compactMap { Color(hex: $0) }

    /// Layout is pure in the spec; body re-runs on every selection click,
    /// so cache instead of recomputing the column/ribbon packing per click.
    private static let layoutMemo = RenderMemo<SankeyLayout.Result>(limit: 16)

    private var layout: SankeyLayout.Result {
        Self.layoutMemo.value(for: cacheKey) { SankeyLayout.layout(spec) }
    }

    private var cacheKey: String {
        var hasher = Hasher()
        for link in spec.links {
            hasher.combine(link.from)
            hasher.combine(link.to)
            hasher.combine(link.value)
        }
        return String(hasher.finalize())
    }

    /// Node color: its group's slot when groups are declared, else its
    /// column's slot — adjacent columns never share a hue either way.
    private func color(forNode name: String, column: Int) -> Color {
        if let group = spec.groups[name],
           let index = spec.groupNames.firstIndex(of: group) {
            return Self.palette[index % Self.palette.count]
        }
        return Self.palette[column % Self.palette.count]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }
            GeometryReader { geo in
                canvas(size: geo.size)
            }
            .frame(height: 300)
            if let selected = selectedNode {
                selectionSummary(selected)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    // MARK: Geometry

    private let nodeWidth: CGFloat = 10
    private let labelGutter: CGFloat = 4

    private func nodeRect(_ node: SankeyLayout.Node, in size: CGSize) -> CGRect {
        let columns = max(1, layout.columnCount - 1)
        let usableWidth = size.width - nodeWidth
        let x = layout.columnCount == 1 ? 0 : usableWidth * CGFloat(node.column) / CGFloat(columns)
        return CGRect(
            x: x,
            y: size.height * node.y0,
            width: nodeWidth,
            height: max(2, size.height * (node.y1 - node.y0))
        )
    }

    private func canvas(size: CGSize) -> some View {
        let result = layout
        let nodeRects = Dictionary(uniqueKeysWithValues: result.nodes.map { ($0.name, nodeRect($0, in: size)) })
        let lit = litNodes(result)

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Ribbons under nodes.
                for ribbon in result.ribbons {
                    guard let source = nodeRects[ribbon.from],
                          let target = nodeRects[ribbon.to] else { continue }
                    let isLit = lit == nil || (lit!.contains(ribbon.from) && lit!.contains(ribbon.to))
                    let sourceColumn = result.nodes.first { $0.name == ribbon.from }?.column ?? 0
                    let baseColor = color(forNode: ribbon.from, column: sourceColumn)

                    var path = Path()
                    let x0 = source.maxX
                    let x1 = target.minX
                    let midX = (x0 + x1) / 2
                    let sy0 = size.height * ribbon.sourceY0
                    let sy1 = size.height * ribbon.sourceY1
                    let ty0 = size.height * ribbon.targetY0
                    let ty1 = size.height * ribbon.targetY1
                    path.move(to: CGPoint(x: x0, y: sy0))
                    path.addCurve(to: CGPoint(x: x1, y: ty0),
                                  control1: CGPoint(x: midX, y: sy0),
                                  control2: CGPoint(x: midX, y: ty0))
                    path.addLine(to: CGPoint(x: x1, y: ty1))
                    path.addCurve(to: CGPoint(x: x0, y: sy1),
                                  control1: CGPoint(x: midX, y: ty1),
                                  control2: CGPoint(x: midX, y: sy1))
                    path.closeSubpath()
                    context.fill(path, with: .color(baseColor.opacity(isLit ? 0.35 : 0.08)))
                }
                // Node bars.
                for node in result.nodes {
                    guard let rect = nodeRects[node.name] else { continue }
                    let isLit = lit == nil || lit!.contains(node.name)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 2),
                        with: .color(color(forNode: node.name, column: node.column).opacity(isLit ? 1 : 0.25))
                    )
                }
            }
            // Labels + hit targets as SwiftUI views (selectable, accessible).
            ForEach(result.nodes) { node in
                if let rect = nodeRects[node.name] {
                    nodeLabel(node, rect: rect, canvasSize: size, lit: lit)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedNode = nil }
    }

    private func nodeLabel(_ node: SankeyLayout.Node, rect: CGRect, canvasSize: CGSize, lit: Set<String>?) -> some View {
        // Last-column labels lean left of the bar; all others to the right.
        let isLastColumn = node.column == layout.columnCount - 1
        let isLit = lit == nil || lit!.contains(node.name)
        return Text(node.name)
            .font(.system(size: 10, weight: selectedNode == node.name ? .semibold : .regular))
            .foregroundStyle(isLit ? Theme.primary : Theme.tertiary)
            .lineLimit(1)
            .fixedSize()
            .position(
                x: isLastColumn ? rect.minX - labelGutter - labelWidth(node.name) / 2
                                : rect.maxX + labelGutter + labelWidth(node.name) / 2,
                y: rect.midY
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedNode = selectedNode == node.name ? nil : node.name
            }
    }

    /// Approximate label width for positioning (Canvas has no text metrics
    /// at layout time; 5.4pt/char at 10pt is close enough for placement).
    private func labelWidth(_ text: String) -> CGFloat {
        CGFloat(text.count) * 5.4
    }

    /// Selected node + everything it directly exchanges flow with.
    private func litNodes(_ result: SankeyLayout.Result) -> Set<String>? {
        guard let selected = selectedNode else { return nil }
        var lit: Set<String> = [selected]
        for ribbon in result.ribbons {
            if ribbon.from == selected { lit.insert(ribbon.to) }
            if ribbon.to == selected { lit.insert(ribbon.from) }
        }
        return lit
    }

    private func selectionSummary(_ name: String) -> some View {
        let inbound = spec.links.filter { $0.to == name }
        let outbound = spec.links.filter { $0.from == name }
        let inTotal = inbound.reduce(0) { $0 + $1.value }
        let outTotal = outbound.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 3) {
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
            HStack(spacing: 10) {
                if inTotal > 0 {
                    Text("in \(fmt(inTotal))")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
                if outTotal > 0 {
                    Text("out \(fmt(outTotal))")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
                if inTotal > 0 && outTotal > 0 && abs(inTotal - outTotal) > 0.001 {
                    Text("Δ \(fmt(outTotal - inTotal))")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Outflow differs from inflow — unaccounted flow")
                }
            }
            ForEach(outbound.indices, id: \.self) { index in
                let link = outbound[index]
                Text("→ \(link.to): \(fmt(link.value))")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func fmt(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
