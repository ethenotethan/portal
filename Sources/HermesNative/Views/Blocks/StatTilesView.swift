import SwiftUI
import Charts

/// Renders a ```stats block as a KPI row: label, compact hero value, signed
/// delta (color = direction × whether up is good), optional sparkline with
/// the current period accented. Follows the dataviz stat-tile contract —
/// values in proportional figures (never tabular at display size), labels in
/// text tokens, the sparkline in the de-emphasis hue.
struct StatTilesView: View {
    let json: String
    let isStreaming: Bool

    var body: some View {
        if let spec = StatTileSpec.parse(json) {
            TileFlow(tiles: spec.tiles)
        } else if isStreaming {
            // Mid-stream partial JSON — render nothing rather than an error.
            EmptyView()
        } else {
            ChartErrorNote(source: json)
        }
    }
}

/// Wrapping row of tiles: plain Layout (no ScrollView) so PDF export
/// rasterizes it correctly, same rationale as the chart legend chips.
private struct TileFlow: View {
    let tiles: [StatTileSpec.Tile]

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8, alignment: .topLeading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(tiles) { tile in
                StatTileCard(tile: tile)
            }
        }
    }
}

private struct StatTileCard: View {
    let tile: StatTileSpec.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tile.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(tile.value.display)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = tile.unit {
                    Text(unit)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.tertiary)
                }
            }

            if let delta = tile.delta {
                deltaRow(delta)
            }

            if let trend = tile.trend, trend.count >= 2 {
                Sparkline(points: trend)
                    .frame(height: 22)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private func deltaRow(_ delta: Double) -> some View {
        // Color = direction × whether up is good; zero is neutral.
        let up = delta > 0
        let good = delta == 0 ? nil : (up == tile.upIsGood)
        let color: Color = good == nil ? Theme.secondary : (good! ? .green : .red)
        return HStack(spacing: 4) {
            if delta != 0 {
                Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(formattedDelta(delta))
                .font(.system(size: 11, weight: .semibold))
            if let context = tile.deltaLabel {
                Text(context)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .foregroundStyle(color)
    }

    private func formattedDelta(_ delta: Double) -> String {
        let magnitude = abs(delta).formatted(.number.precision(.fractionLength(0...1)))
        if delta == 0 { return "±0%" }
        return (delta > 0 ? "+" : "−") + magnitude + "%"
    }
}

/// 12-point-style sparkline: the series in the de-emphasis hue, the final
/// (current) point accented. Pure Path — no axes, no interaction.
private struct Sparkline: View {
    let points: [Double]

    var body: some View {
        GeometryReader { geo in
            let path = linePath(in: geo.size)
            path
                .stroke(Theme.tertiary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            if let last = position(of: points.count - 1, in: geo.size) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .position(last)
            }
        }
        .accessibilityHidden(true)  // the value + delta carry the information
    }

    private func linePath(in size: CGSize) -> Path {
        var path = Path()
        for index in points.indices {
            guard let point = position(of: index, in: size) else { continue }
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        return path
    }

    private func position(of index: Int, in size: CGSize) -> CGPoint? {
        guard points.count > 1, index >= 0, index < points.count,
              let lo = points.min(), let hi = points.max() else { return nil }
        let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
        // Inset vertically so the accent dot never clips.
        let usable = size.height - 6
        let normalized = hi > lo ? (points[index] - lo) / (hi - lo) : 0.5
        let y = 3 + usable * (1 - CGFloat(normalized))
        return CGPoint(x: x, y: y)
    }
}

/// Non-streaming parse failure: a quiet note with the source, not the loud
/// orange chart error — a stats row is decoration, not data of record.
private struct ChartErrorNote: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't parse stats block")
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
