import SwiftUI
import Charts

// MARK: - Kind palette

/// Fixed-order categorical palette for event kinds, validated for the app's
/// dark surface (#1a1a1a): CVD ΔE ≥ 8.4 adjacent, normal-vision ΔE ≥ 19.3,
/// all ≥ 3:1 contrast. Kind also gets its own y-lane on the chart, so color
/// never carries identity alone. `.other` is the muted catch-all.
///
/// This palette covers Centaur's kinds, which are fixed by its ingestion
/// pipeline. Hermes kinds are declared by the wiki (`type: event-type` pages)
/// and resolve through `WikiEventTypeRegistry` instead — see
/// `WikiEventPresentation`, which picks between the two and is what views
/// should call.
internal enum WikiEventKindStyle {
    internal static func color(for kind: WikiEventKind) -> Color {
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
    internal static let laneOrder: [WikiEventKind] = [
        .githubPR, .linear, .slack, .drive, .directive, .openrouterStats, .other,
    ]
}

// MARK: - WikiEventPresentation

/// How to draw one event kind, resolved from whichever authority owns it.
///
/// Two backends disagree about who defines the taxonomy, and both are right for
/// their own data. Centaur's kinds come from its pipeline, so the validated
/// palette above is authoritative and a wiki page can't know better. Hermes'
/// kinds are declared by the wiki itself, so a `type: event-type` page is
/// authoritative and a compiled-in palette would be exactly the closed
/// vocabulary #123 set out to remove.
///
/// So this resolves the wiki's declaration when there is one, and falls back to
/// the built-in palette when there isn't. Every view goes through here rather
/// than calling `WikiEventKindStyle` directly, so neither backend's kinds get
/// drawn by the other's rules.
internal struct WikiEventPresentation {
    /// The wiki's declared taxonomy — empty for Centaur, and for a Hermes wiki
    /// that has declared nothing yet.
    internal let registry: WikiEventTypeRegistry

    internal static let empty = WikiEventPresentation(registry: .empty)

    /// Color for a wire kind. A declared type's color wins; otherwise a
    /// recognized Centaur kind uses the validated palette; otherwise the
    /// registry's hashed-but-stable derivation keeps unknown kinds distinct
    /// instead of merging them into one "other" bucket.
    internal func color(for kindRaw: String) -> Color {
        let resolved = registry.resolve(kindRaw)
        if resolved.isDeclared { return resolved.color }
        let builtIn = WikiEventKind(wire: kindRaw)
        if builtIn != .other { return WikiEventKindStyle.color(for: builtIn) }
        // An empty kind is genuinely unknown, not a distinct category — give it
        // the muted catch-all rather than a confident derived hue.
        if kindRaw.trimmingCharacters(in: .whitespaces).isEmpty {
            return WikiEventKindStyle.color(for: .other)
        }
        return resolved.color
    }

    /// Display label for a wire kind, by the same precedence as `color`.
    internal func label(for kindRaw: String) -> String {
        let resolved = registry.resolve(kindRaw)
        if resolved.isDeclared { return resolved.label }
        let builtIn = WikiEventKind(wire: kindRaw)
        if builtIn != .other { return builtIn.displayName }
        if kindRaw.trimmingCharacters(in: .whitespaces).isEmpty { return "Unclassified" }
        return resolved.label
    }

    /// Definition page for a wire kind, when a wiki page declares it — the
    /// click-through target. nil whenever the kind is drawn from the built-in
    /// palette, since there's no page to open.
    internal func pagePath(for kindRaw: String) -> String? {
        registry.resolve(kindRaw).pagePath
    }

    /// Lane order for the plot's y-axis: kinds actually present, declared ones
    /// first in their declared lane order, then the rest by the built-in slot
    /// order, then anything left alphabetically. Deterministic — a lane that
    /// reshuffles between loads makes the plot unreadable.
    internal func lanes(present kinds: [String]) -> [String] {
        let unique = Array(Set(kinds))
        return unique.sorted { lhs, rhs in
            let (a, b) = (sortKey(lhs), sortKey(rhs))
            if a != b { return a < b }
            return lhs < rhs
        }
    }

    /// Lower sorts higher on the chart. Declared lanes come from the wiki;
    /// built-in kinds sit below them in palette order; unrecognized kinds last.
    private func sortKey(_ kindRaw: String) -> Int {
        let resolved = registry.resolve(kindRaw)
        if resolved.isDeclared { return resolved.lane }
        let builtIn = WikiEventKind(wire: kindRaw)
        if builtIn != .other,
           let slot = WikiEventKindStyle.laneOrder.firstIndex(of: builtIn) {
            return WikiEventTypeRegistry.derivedLane + slot
        }
        return WikiEventTypeRegistry.derivedLane + WikiEventKindStyle.laneOrder.count
    }
}

// MARK: - Events chart

/// Dot plot of ingestion events: x = event time, y = kind lane, color by
/// kind. Estimated-time events (ingest time only) render as hollow diamonds.
/// Selection is by event id, shared with the Event Feed: tapping a dot
/// highlights (and scrolls to) the feed row, and selecting a feed row lights
/// up the dot — the feed row is the detail surface.
internal struct WikiEventDotChart: View {
    internal let events: [WikiTimelineEvent]
    internal let window: ClosedRange<Date>
    @Binding internal var selectedEventID: String?
    /// How to color and order kinds — the wiki's taxonomy when it has one.
    internal var presentation: WikiEventPresentation = .empty

    /// Lanes actually present, ordered by the presentation layer (declared
    /// lanes first, then built-in palette order).
    private var lanes: [String] {
        presentation.lanes(present: events.map(\.kindRaw))
    }

    internal var body: some View {
        let lanes = self.lanes
        Chart {
            ForEach(events) { event in
                if let date = event.eventDate {
                    PointMark(
                        x: .value("Time", date),
                        y: .value("Kind", presentation.label(for: event.kindRaw))
                    )
                    .foregroundStyle(
                        presentation.color(for: event.kindRaw)
                            .opacity(dimmed(event) ? 0.28 : 0.9)
                    )
                    .symbol(event.eventTimeEstimated ? .diamond : .circle)
                    .symbolSize(selectedEventID == event.id ? 130 : 55)
                }
            }
        }
        .chartYScale(domain: lanes.map { presentation.label(for: $0) })
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
        selectedEventID != nil && selectedEventID != event.id
    }

    // MARK: Tap selection

    private func chartTapOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .onTapGesture { location in
                    selectedEventID = nearestEvent(to: location, proxy: proxy, geo: geo)?.id
                }
        }
    }

    private func position(of event: WikiTimelineEvent, proxy: ChartProxy, geo: GeometryProxy) -> CGPoint? {
        guard let date = event.eventDate,
              let x = proxy.position(forX: date),
              let y = proxy.position(forY: presentation.label(for: event.kindRaw)),
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
internal struct WikiRevisionsChart: View {
    internal let timeline: WikiRevisionsTimeline
    internal let window: ClosedRange<Date>
    internal let showCumulative: Bool

    private static let accrued = Color(hex: "3987e5") ?? .blue

    internal var body: some View {
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

/// Legend with per-kind counts (events_by_kind), in lane order so it reads
/// top-to-bottom against the chart. Rendered above the dot chart; identity is
/// also carried by the y-lanes.
///
/// Every kind gets its own row. The previous version collapsed anything outside
/// the built-in palette into a single "Other N" row, which on a Hermes wiki
/// would have merged every wiki-declared kind into one — the legend has to name
/// what the wiki named, and a declared kind's definition page is clickable.
internal struct WikiEventKindLegend: View {
    /// Wire-kind string → count, from the event log response.
    internal let eventsByKind: [String: Int]
    internal var presentation: WikiEventPresentation = .empty
    /// Opens a kind's definition page. nil (or a kind with no page) renders the
    /// row as plain text.
    internal var onOpenKindPage: ((String) -> Void)?

    /// Kinds with a non-zero count, in the chart's lane order.
    private var entries: [(kind: String, count: Int)] {
        let present = eventsByKind.filter { $0.value > 0 }
        return presentation.lanes(present: Array(present.keys))
            .compactMap { kind in
                present[kind].map { (kind, $0) }
            }
    }

    internal var body: some View {
        FlowLayout(spacing: 10) {
            ForEach(entries, id: \.kind) { entry in
                legendRow(kind: entry.kind, count: entry.count)
            }
        }
    }

    @ViewBuilder
    private func legendRow(kind: String, count: Int) -> some View {
        if let path = presentation.pagePath(for: kind), let onOpenKindPage {
            Button { onOpenKindPage(path) } label: {
                swatch(kind: kind, count: count, declared: true)
            }
            .buttonStyle(.borderless)
            .help("Open \(path) — what the wiki says this kind is")
        } else {
            swatch(kind: kind, count: count, declared: false)
        }
    }

    private func swatch(kind: String, count: Int, declared: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(presentation.color(for: kind))
                .frame(width: 8, height: 8)
            Text(presentation.label(for: kind))
                .font(.caption2.weight(.medium))
                .foregroundStyle(declared ? Theme.accent : Theme.primary)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }
}
