import Charts
import SwiftUI

/// Renders a ```timeline / ```gantt JSON block: one row per item, duration
/// bars between start/end, diamond milestones, colored by group (or lane
/// when no groups are declared). Swift Charts only — PDF-safe.
/// Scrub horizontally to read out what was active on a date.
struct TimelineBlockView: View {
    let json: String
    let isStreaming: Bool

    var body: some View {
        if let spec = TimelineSpec.parse(json) {
            TimelineCard(spec: spec)
        } else if isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't parse timeline block")
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

private struct TimelineCard: View {
    let spec: TimelineSpec
    @State private var selectedDate: Date?

    /// Shared categorical palette (chart/graph/map/sankey parity).
    private static let palette: [Color] = [
        "#3987e5", "#008300", "#d55181", "#c98500",
        "#199e70", "#d95926", "#9085e9", "#e66767",
    ].compactMap { Color(hex: $0) }

    /// Rows in lane order, then by start within a lane. Row identity is the
    /// y-axis category, so duplicate labels get invisible space suffixes
    /// (same trick as waterfall's duplicate x labels).
    private var rows: [(item: TimelineSpec.Item, axisLabel: String)] {
        let laneRank = Dictionary(uniqueKeysWithValues: spec.lanes.enumerated().map { ($1, $0) })
        let ordered = spec.items.sorted {
            let left = laneRank[$0.lane] ?? 0
            let right = laneRank[$1.lane] ?? 0
            return left == right ? $0.start < $1.start : left < right
        }
        var seen: [String: Int] = [:]
        return ordered.map { item in
            let count = seen[item.label, default: 0]
            seen[item.label] = count + 1
            return (item, item.label + String(repeating: " ", count: count))
        }
    }

    /// Color dimension: declared groups win; otherwise lanes (a single
    /// implicit lane means one hue and no legend).
    private var colorKey: (TimelineSpec.Item) -> String {
        spec.groups.isEmpty ? { $0.lane } : { $0.group ?? "other" }
    }

    private var colorDomain: [String] {
        spec.groups.isEmpty ? spec.lanes : spec.groups + (spec.items.contains { $0.group == nil } ? ["other"] : [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
            }
            chart
            if let date = selectedDate {
                readout(for: date)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private var chart: some View {
        let rows = self.rows
        let height = min(480, max(120, CGFloat(rows.count) * 26 + 44))

        return Chart {
            ForEach(rows, id: \.item.id) { row in
                if row.item.isMilestone {
                    PointMark(
                        x: .value("Date", row.item.start),
                        y: .value("Item", row.axisLabel)
                    )
                    .symbol(.diamond)
                    .symbolSize(120)
                    .foregroundStyle(by: .value("Group", colorKey(row.item)))
                } else {
                    BarMark(
                        xStart: .value("Start", row.item.start),
                        xEnd: .value("End", row.item.end),
                        y: .value("Item", row.axisLabel),
                        height: .fixed(12)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Group", colorKey(row.item)))
                }
            }
            if let range = spec.dateRange, range.contains(Date()) {
                RuleMark(x: .value("Today", Date()))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Theme.tertiary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("today")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
            }
        }
        .chartForegroundStyleScale(domain: colorDomain, range: Self.palette)
        .chartLegend(colorDomain.count > 1 ? .visible : .hidden)
        .chartXSelection(value: $selectedDate)
        .chartYAxis {
            AxisMarks(preset: .aligned) { _ in
                AxisValueLabel()
                    .font(.system(size: 10))
            }
        }
        .frame(height: height)
    }

    /// Items whose span contains the scrubbed date (milestones match ±12h).
    private func readout(for date: Date) -> some View {
        let active = spec.items.filter {
            $0.isMilestone
                ? abs($0.start.timeIntervalSince(date)) < 43_200
                : ($0.start...$0.end).contains(date)
        }
        return VStack(alignment: .leading, spacing: 3) {
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.primary)
            if active.isEmpty {
                Text("Nothing scheduled")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            ForEach(active) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.isMilestone ? "diamond.fill" : "calendar")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.secondary)
                    Text(item.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.secondary)
                    if !item.isMilestone {
                        Text(durationText(item))
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    if let note = item.note {
                        Text("— \(note)")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func durationText(_ item: TimelineSpec.Item) -> String {
        let days = item.duration / 86_400
        if days >= 1 {
            return days.formatted(.number.precision(.fractionLength(0))) + "d"
        }
        let hours = item.duration / 3_600
        return hours.formatted(.number.precision(.fractionLength(0...1))) + "h"
    }
}
