import SwiftUI
import Charts

/// Runtime activity chart for the Centaur workflows panel — the analogue of
/// the Hermes cron dashboard's "Activation Volume" chart. Two stacked views
/// over the same horizon control:
///
/// - **Volume**: stacked bars of run counts per time bucket, colored by
///   outcome (completed/failed/cancelled/active). Same visual language as
///   the cron chart (Theme.success/red) so operators read both dashboards
///   the same way.
/// - **Duration**: per-run points (created→updated span) over time, colored
///   by workflow, on a log-friendly scale — surfaces slow runs and drift the
///   volume view hides.
struct CentaurWorkflowActivityChart: View {
    let runs: [CentaurWorkflowRun]

    @State private var horizon: Horizon = .day
    @State private var mode: Mode = .volume

    enum Mode: String, CaseIterable {
        case volume = "Volume"
        case duration = "Duration"
    }

    enum Horizon: String, CaseIterable {
        case hour = "1h"
        case day = "24h"
        case week = "7d"
        case all = "All"

        var cutoff: Date? {
            switch self {
            case .hour: return Calendar.current.date(byAdding: .hour, value: -1, to: Date())
            case .day: return Calendar.current.date(byAdding: .hour, value: -24, to: Date())
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .all: return nil
            }
        }

        var bucketComponent: Calendar.Component {
            switch self {
            case .hour: return .minute
            case .day, .week: return .hour
            case .all: return .day
            }
        }

        var xAxisFormat: Date.FormatStyle {
            switch self {
            case .hour: return .dateTime.hour().minute()
            case .day: return .dateTime.hour()
            case .week: return .dateTime.weekday().hour()
            case .all: return .dateTime.day().month()
            }
        }
    }

    // MARK: - Data shaping

    private var visibleRuns: [CentaurWorkflowRun] {
        guard let cutoff = horizon.cutoff else { return runs }
        return runs.filter { ($0.createdAt ?? .distantPast) >= cutoff }
    }

    private struct Bucket: Identifiable {
        let start: Date
        var completed = 0
        var failed = 0
        var cancelled = 0
        var active = 0
        var id: Date { start }
    }

    private var buckets: [Bucket] {
        let calendar = Calendar.current
        let component = horizon.bucketComponent
        var byStart: [Date: Bucket] = [:]
        for run in visibleRuns {
            guard let created = run.createdAt else { continue }
            let start = calendar.dateInterval(of: component, for: created)?.start ?? created
            var bucket = byStart[start] ?? Bucket(start: start)
            switch run.status.lowercased() {
            case "completed": bucket.completed += 1
            case "failed": bucket.failed += 1
            case "cancelled", "canceled": bucket.cancelled += 1
            default: bucket.active += 1
            }
            byStart[start] = bucket
        }
        return byStart.values.sorted { $0.start < $1.start }
    }

    private struct DurationPoint: Identifiable {
        let id: String
        let workflow: String
        let at: Date
        let seconds: Double
        let failed: Bool
    }

    private var durationPoints: [DurationPoint] {
        visibleRuns.compactMap { run in
            guard !run.isActive,
                  let created = run.createdAt, let updated = run.updatedAt,
                  updated > created else { return nil }
            return DurationPoint(
                id: run.runID,
                workflow: run.workflowName,
                at: created,
                seconds: updated.timeIntervalSince(created),
                failed: run.status.lowercased() == "failed"
            )
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)

                Spacer()

                Picker("", selection: $horizon) {
                    ForEach(Horizon.allCases, id: \.self) { horizon in
                        Text(horizon.rawValue).tag(horizon)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
            }

            if visibleRuns.isEmpty {
                Text("No runs in this window")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                switch mode {
                case .volume: volumeChart
                case .duration: durationChart
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    // MARK: - Volume

    /// Outcome → color, matching the cron dashboard's OK/Error language.
    private static let volumeScale: KeyValuePairs<String, Color> = [
        "Completed": Theme.success,
        "Failed": .red,
        "Cancelled": .orange,
        "Active": Theme.accent,
    ]

    private var volumeChart: some View {
        Chart(buckets) { bucket in
            BarMark(x: .value("Time", bucket.start), y: .value("Runs", bucket.completed))
                .foregroundStyle(by: .value("Status", "Completed"))
                .cornerRadius(2)
            if bucket.failed > 0 {
                BarMark(x: .value("Time", bucket.start), y: .value("Runs", bucket.failed))
                    .foregroundStyle(by: .value("Status", "Failed"))
                    .cornerRadius(2)
            }
            if bucket.cancelled > 0 {
                BarMark(x: .value("Time", bucket.start), y: .value("Runs", bucket.cancelled))
                    .foregroundStyle(by: .value("Status", "Cancelled"))
                    .cornerRadius(2)
            }
            if bucket.active > 0 {
                BarMark(x: .value("Time", bucket.start), y: .value("Runs", bucket.active))
                    .foregroundStyle(by: .value("Status", "Active"))
                    .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale(Self.volumeScale)
        .chartLegend(position: .top, alignment: .trailing) {
            HStack(spacing: 10) {
                legendDot(Theme.success, "Completed")
                legendDot(.red, "Failed")
                legendDot(.orange, "Cancelled")
                legendDot(Theme.accent, "Active")
            }
        }
        .modifier(ActivityAxes(format: horizon.xAxisFormat))
        .frame(height: 150)
    }

    // MARK: - Duration

    private var durationChart: some View {
        Chart(durationPoints) { point in
            PointMark(
                x: .value("Time", point.at),
                y: .value("Duration", point.seconds)
            )
            .foregroundStyle(by: .value("Workflow", point.workflow))
            .symbol(point.failed ? .cross : .circle)
            .symbolSize(point.failed ? 55 : 30)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisValueLabel {
                    if let secs = value.as(Double.self) {
                        Text(Self.durationLabel(secs))
                            .font(.caption2)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(Theme.border)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisValueLabel(format: horizon.xAxisFormat)
                    .font(.caption2)
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                    .foregroundStyle(Theme.border)
            }
        }
        .chartLegend(position: .top, alignment: .trailing)
        .frame(height: 150)
    }

    static func durationLabel(_ seconds: Double) -> String {
        if seconds >= 3600 { return "\(Int(seconds / 3600))h" }
        if seconds >= 60 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds))s"
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// Shared axis styling for the volume chart (cron-dashboard parity).
private struct ActivityAxes: ViewModifier {
    let format: Date.FormatStyle

    func body(content: Content) -> some View {
        content
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                    AxisValueLabel(format: format)
                        .font(.caption2)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(Theme.border)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisValueLabel()
                        .font(.caption2)
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.3))
                        .foregroundStyle(Theme.border)
                }
            }
    }
}
