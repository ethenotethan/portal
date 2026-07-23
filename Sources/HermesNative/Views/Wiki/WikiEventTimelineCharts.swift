import SwiftUI
import Charts

// MARK: - Kind palette

/// Fixed-order categorical palette for event kinds, validated for the app's
/// dark surface (#1a1a1a): CVD ΔE ≥ 8.4 adjacent, normal-vision ΔE ≥ 19.3,
/// all ≥ 3:1 contrast. Kind also gets its own y-lane on the chart, so color
/// never carries identity alone. `.other` is the muted catch-all.
enum WikiEventKindStyle {
    static func color(for kind: WikiEventKind) -> Color {
        switch kind {
        case .githubPR: return Color(hex: "3987e5") ?? .blue
        case .linear: return Color(hex: "d95926") ?? .orange
        case .slack: return Color(hex: "199e70") ?? .green
        case .drive: return Color(hex: "c98500") ?? .yellow
        case .directive: return Color(hex: "d55181") ?? .pink
        case .openrouterStats: return Color(hex: "9085e9") ?? .purple
        case .other: return Color(hex: "8a8f98") ?? .gray
        }
    }

    /// Fixed lane order, top-to-bottom on the events chart.
    static let laneOrder: [WikiEventKind] = [
        .githubPR, .linear, .slack, .drive, .directive, .openrouterStats, .other,
    ]
}

// MARK: - Events chart

/// Dot plot of ingestion events: x = event time, y = kind lane, color by
/// kind. Estimated-time events (ingest time only) render as hollow diamonds.
/// Tap a dot to select it; the parent anchors the detail popover at the
/// selected dot's plot position.
struct WikiEventDotChart: View {
    let events: [WikiTimelineEvent]
    let window: ClosedRange<Date>
    @Binding var selectedEvent: WikiTimelineEvent?
    /// Detail card content for the selected event's popover.
    let detail: (WikiTimelineEvent) -> WikiEventDetailCard

    /// Lanes actually present, in fixed slot order (unused kinds drop out).
    private var lanes: [WikiEventKind] {
        let present = Set(events.map(\.kind))
        return WikiEventKindStyle.laneOrder.filter { present.contains($0) }
    }

    var body: some View {
        let lanes = self.lanes
        Chart {
            ForEach(events) { event in
                if let date = event.eventDate {
                    PointMark(
                        x: .value("Time", date),
                        y: .value("Kind", event.kind.displayName)
                    )
                    .foregroundStyle(
                        WikiEventKindStyle.color(for: event.kind)
                            .opacity(dimmed(event) ? 0.28 : 0.9)
                    )
                    .symbol(event.eventTimeEstimated ? .diamond : .circle)
                    .symbolSize(selectedEvent?.id == event.id ? 130 : 55)
                }
            }
        }
        .chartYScale(domain: lanes.map(\.displayName))
        .chartXScale(domain: window.lowerBound...window.upperBound)
        .chartXAxis { timeAxis }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let name = value.as(String.self) {
                        Text(name)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { $0.background(Theme.background.opacity(0.4)) }
        .chartOverlay { proxy in
            chartTapOverlay(proxy: proxy)
        }
        .frame(height: max(140, CGFloat(lanes.count) * 34 + 40))
    }

    private func dimmed(_ event: WikiTimelineEvent) -> Bool {
        selectedEvent != nil && selectedEvent?.id != event.id
    }

    // MARK: Tap selection + popover anchor

    private func chartTapOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        selectedEvent = nearestEvent(to: location, proxy: proxy, geo: geo)
                    }

                // Invisible 1pt anchor placed at the selected dot; the
                // popover attaches here so it points at the mark itself.
                if let selected = selectedEvent,
                   let anchorPoint = position(of: selected, proxy: proxy, geo: geo) {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .position(anchorPoint)
                        .popover(
                            isPresented: Binding(
                                get: { selectedEvent != nil },
                                set: { if !$0 { selectedEvent = nil } }
                            )
                        ) {
                            detail(selected)
                                .presentationCompactAdaptation(.popover)
                        }
                }
            }
        }
    }

    private func position(of event: WikiTimelineEvent, proxy: ChartProxy, geo: GeometryProxy) -> CGPoint? {
        guard let date = event.eventDate,
              let x = proxy.position(forX: date),
              let y = proxy.position(forY: event.kind.displayName),
              let plotFrame = proxy.plotFrame else { return nil }
        let origin = geo[plotFrame].origin
        return CGPoint(x: origin.x + x, y: origin.y + y)
    }

    /// Nearest dot within a 22pt hit radius (targets bigger than the mark).
    private func nearestEvent(to location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) -> WikiTimelineEvent? {
        var best: (event: WikiTimelineEvent, dist: CGFloat)?
        for event in events {
            guard let p = position(of: event, proxy: proxy, geo: geo) else { continue }
            let dist = hypot(p.x - location.x, p.y - location.y)
            if dist < (best?.dist ?? .infinity) { best = (event, dist) }
        }
        guard let best, best.dist <= 22 else { return nil }
        return best.event
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
            AxisGridLine().foregroundStyle(Theme.border.opacity(0.25))
            AxisTick().foregroundStyle(Theme.tertiary)
            AxisValueLabel()
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Revisions chart

/// Page-edit volume (the OUTPUT side): per-bucket revision bars, or the
/// cumulative "knowledge accrued" curve seeded from the pre-window baseline.
/// One measure per view — the toggle swaps them instead of dual-axing.
struct WikiRevisionsChart: View {
    let timeline: WikiRevisionsTimeline
    let window: ClosedRange<Date>
    let showCumulative: Bool

    private static let accrued = Color(hex: "3987e5") ?? .blue

    var body: some View {
        Group {
            if showCumulative {
                cumulativeChart
            } else {
                barsChart
            }
        }
        .chartXScale(domain: window.lowerBound...window.upperBound)
        .chartXAxis { timeAxis }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.border.opacity(0.25))
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .chartPlotStyle { $0.background(Theme.background.opacity(0.4)) }
        .frame(height: 130)
    }

    private var barsChart: some View {
        Chart(timeline.buckets.filter { $0.bucket != nil }) { bucket in
            BarMark(
                x: .value("Bucket", bucket.bucket ?? .now, unit: calendarUnit),
                y: .value("Revisions", bucket.count)
            )
            .foregroundStyle(Theme.accent.opacity(0.8))
            .cornerRadius(2)
        }
    }

    private var cumulativeChart: some View {
        Chart(cumulativeData, id: \.bucket) { point in
            AreaMark(
                x: .value("Time", point.bucket),
                y: .value("Total revisions", point.total)
            )
            .foregroundStyle(
                LinearGradient(
                    colors: [Self.accrued.opacity(0.28), Self.accrued.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Time", point.bucket),
                y: .value("Total revisions", point.total)
            )
            .foregroundStyle(Self.accrued)
            .lineStyle(StrokeStyle(lineWidth: 2))
            .interpolationMethod(.monotone)
        }
    }

    /// Cumulative curve pinned to the window edges: seeds at the baseline on
    /// the left so the accrued height is true, ends at the final total.
    private var cumulativeData: [(bucket: Date, total: Int)] {
        var points = timeline.cumulativePoints
        if let first = points.first, first.bucket > window.lowerBound {
            points.insert((window.lowerBound, timeline.baseline), at: 0)
        }
        if let last = points.last, last.bucket < window.upperBound {
            points.append((window.upperBound, last.total))
        }
        if points.isEmpty {
            points = [(window.lowerBound, timeline.baseline), (window.upperBound, timeline.baseline)]
        }
        return points
    }

    /// Match the bar width to the server's adaptive date_trunc unit.
    private var calendarUnit: Calendar.Component {
        switch timeline.unit {
        case "hour": return .hour
        case "week": return .weekOfYear
        case "month": return .month
        default: return .day
        }
    }

    @AxisContentBuilder
    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 5)) { _ in
            AxisGridLine().foregroundStyle(Theme.border.opacity(0.25))
            AxisTick().foregroundStyle(Theme.tertiary)
            AxisValueLabel()
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - Kind legend

/// Legend with per-kind counts (events_by_kind), fixed slot order. Rendered
/// above the dot chart; identity is also carried by the y-lanes.
struct WikiEventKindLegend: View {
    /// Wire-kind string → count, from the timeline response.
    let eventsByKind: [String: Int]

    private var entries: [(kind: WikiEventKind, label: String, count: Int)] {
        // Known kinds in slot order first, then unknown wire kinds folded
        // into their own labeled rows under the "other" color.
        var rows: [(WikiEventKind, String, Int)] = []
        var consumed = Set<String>()
        for kind in WikiEventKindStyle.laneOrder where kind != .other {
            if let count = eventsByKind[kind.rawValue], count > 0 {
                rows.append((kind, kind.displayName, count))
                consumed.insert(kind.rawValue)
            }
        }
        let otherTotal = eventsByKind
            .filter { !consumed.contains($0.key) }
            .values.reduce(0, +)
        if otherTotal > 0 {
            rows.append((.other, WikiEventKind.other.displayName, otherTotal))
        }
        return rows
    }

    var body: some View {
        FlowLayout(spacing: 10) {
            ForEach(entries, id: \.label) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(WikiEventKindStyle.color(for: entry.kind))
                        .frame(width: 8, height: 8)
                    Text(entry.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.primary)
                    Text("\(entry.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
    }
}
