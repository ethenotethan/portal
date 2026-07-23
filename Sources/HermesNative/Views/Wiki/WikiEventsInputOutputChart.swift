import SwiftUI
import Charts

// MARK: - WikiEventsInputOutputChart

/// The input→output story the two endpoints were designed to tell: raw input
/// events (stacked by kind, bucketed client-side to the server's revision
/// unit) over output page revisions per bucket — two x-aligned charts
/// sharing one time domain, NEVER a dual-axis chart (different measures get
/// different plots; the shared x carries the correlation).
struct WikiEventsInputOutputChart: View {
    let events: [WikiTimelineEvent]
    let revisions: WikiRevisionsTimeline
    let window: ClosedRange<Date>

    /// (bucket date, kind) → event count, in the fixed kind slot order.
    private struct InputBucket: Identifiable {
        let bucket: Date
        let kind: WikiEventKind
        let count: Int
        var id: String { "\(bucket.timeIntervalSince1970)-\(kind.rawValue)" }
    }

    /// Client-side bucketing matched to the server's adaptive unit so the
    /// input bars line up column-for-column with the revision bars.
    private var inputBuckets: [InputBucket] {
        let calendar = Calendar.current
        var counts: [Date: [WikiEventKind: Int]] = [:]
        for event in events {
            guard let date = event.eventDate else { continue }
            guard let bucket = truncate(date, calendar: calendar) else { continue }
            counts[bucket, default: [:]][event.kind, default: 0] += 1
        }
        return counts.flatMap { bucket, byKind in
            WikiEventKindStyle.laneOrder.compactMap { kind in
                byKind[kind].map { InputBucket(bucket: bucket, kind: kind, count: $0) }
            }
        }
        .sorted { ($0.bucket, $0.kind.rawValue) < ($1.bucket, $1.kind.rawValue) }
    }

    private func truncate(_ date: Date, calendar: Calendar) -> Date? {
        switch revisions.unit {
        case "hour":
            return calendar.dateInterval(of: .hour, for: date)?.start
        case "week":
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start
        case "month":
            return calendar.dateInterval(of: .month, for: date)?.start
        default:
            return calendar.startOfDay(for: date)
        }
    }

    private var calendarUnit: Calendar.Component {
        switch revisions.unit {
        case "hour": return .hour
        case "week": return .weekOfYear
        case "month": return .month
        default: return .day
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WikiEventsSectionLabel(
                "Input → output",
                detail: "events in (by kind, per \(revisions.unit)) vs page edits out"
            )

            chartRow(title: "Events in") { inputChart }
            chartRow(title: "Edits out") { outputChart }
        }
    }

    private func chartRow(title: String, @ViewBuilder chart: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.secondary)
            chart()
        }
    }

    /// Stacked input events per bucket, colored by the same kind palette as
    /// the dot plot / legend (identity follows the entity across charts).
    private var inputChart: some View {
        Chart(inputBuckets) { entry in
            BarMark(
                x: .value("Bucket", entry.bucket, unit: calendarUnit),
                y: .value("Events", entry.count)
            )
            .foregroundStyle(WikiEventKindStyle.color(for: entry.kind).opacity(0.85))
            .cornerRadius(2)
        }
        .chartXScale(domain: window.lowerBound...window.upperBound)
        .chartXAxis { timeAxis }
        .chartYAxis { countAxis }
        .chartPlotStyle { $0.background(Theme.background.opacity(0.4)) }
        .frame(height: 96)
    }

    /// Output revisions per bucket, in the accent hue (a measure, not a
    /// kind — it must not collide with the kind palette).
    private var outputChart: some View {
        Chart(revisions.buckets.filter { $0.bucket != nil }) { bucket in
            BarMark(
                x: .value("Bucket", bucket.bucket ?? .now, unit: calendarUnit),
                y: .value("Revisions", bucket.count)
            )
            .foregroundStyle(Theme.accent.opacity(0.8))
            .cornerRadius(2)
        }
        .chartXScale(domain: window.lowerBound...window.upperBound)
        .chartXAxis { timeAxis }
        .chartYAxis { countAxis }
        .chartPlotStyle { $0.background(Theme.background.opacity(0.4)) }
        .frame(height: 96)
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

    @AxisContentBuilder
    private var countAxis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
            AxisGridLine().foregroundStyle(Theme.border.opacity(0.25))
            AxisValueLabel()
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }
}
