import SwiftUI

/// The numbers behind a graph view — nodes, edges, structure and the graph's own
/// extras — as a compact card anchored to a corner of the canvas. An `Equatable`
/// value view over a precomputed `GraphStats`, so it re-renders only when the
/// stats change, never when the canvas does.
internal struct GraphStatsPanel: View, Equatable {
    internal let title: String
    internal let stats: GraphStats

    internal var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
            section("Nodes", rows: [GraphStats.Row(label: "Total", count: stats.nodeCount)] + GraphStats.folded(stats.nodesByKind))
            section("Edges", rows: [GraphStats.Row(label: "Total", count: stats.edgeCount)] + GraphStats.folded(stats.edgesByType)
                    + (stats.danglingEdges > 0 ? [GraphStats.Row(label: "Dangling", count: stats.danglingEdges)] : []))
            structureSection
            ForEach(stats.extras) { extra in
                section(extra.title, rows: GraphStats.folded(extra.rows))
            }
        }
        .padding(12)
        .frame(width: 236, alignment: .leading)
        .background(Theme.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    private var structureSection: some View {
        let degree = stats.maxDegree.map { "\($0.degree) · \($0.label)" } ?? "—"
        return VStack(alignment: .leading, spacing: 3) {
            header("Structure")
            line("Components", value: String(stats.components))
            line("Isolated nodes", value: String(stats.isolatedNodes))
            line("Average degree", value: String(format: "%.2f", stats.averageDegree))
            line("Max degree", value: degree)
        }
    }

    private func section(_ title: String, rows: [GraphStats.Row]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header(title)
            ForEach(rows) { row in
                line(row.label, value: String(row.count))
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.secondary)
    }

    private func line(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
