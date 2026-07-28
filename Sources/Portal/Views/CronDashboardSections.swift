import SwiftUI
import Charts

// Shared building blocks for the Cron Activity surface. Extracted from the
// monolithic CronDashboardView so the same sections render two ways:
//   • iOS / fallback → stacked in a ScrollView (CronDashboardView)
//   • macOS → free-form draggable panels on a canvas (CronDashboardCanvas)
// Each section is a standalone, "dumb" view: it takes the data it needs
// (already time-filtered records + the active horizon) and owns only its own
// popover/expansion state. The host computes `filtered` once and feeds every
// section, so they always agree on the window.
// CronJobCard lives in CronJobCard.swift.

// MARK: - Time horizon

/// The activation-history window the whole surface is scoped to. Drives record
/// filtering and every chart's bucket size + axis format.
internal enum CronTimeHorizon: String, CaseIterable {
    case hour = "1h"
    case day = "24h"
    case week = "7d"
    case month = "30d"
    case all = "All"

    internal var cutoff: Date? {
        switch self {
        case .hour: return Calendar.current.date(byAdding: .hour, value: -1, to: Date())
        case .day: return Calendar.current.date(byAdding: .hour, value: -24, to: Date())
        case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
        case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
        case .all: return nil
        }
    }

    internal var bucketComponent: Calendar.Component {
        switch self {
        case .hour: return .minute
        case .day: return .hour
        case .week: return .hour
        case .month: return .day
        case .all: return .day
        }
    }

    internal var xAxisFormat: Date.FormatStyle {
        switch self {
        case .hour: return .dateTime.hour().minute()
        case .day: return .dateTime.hour()
        case .week: return .dateTime.weekday().hour()
        case .month: return .dateTime.day().month()
        case .all: return .dateTime.month().year()
        }
    }

    internal var timelineFormat: Date.FormatStyle {
        switch self {
        case .hour: return .dateTime.hour().minute()
        case .day: return .dateTime.hour().minute()
        case .week: return .dateTime.weekday().hour()
        case .month: return .dateTime.day().month()
        case .all: return .dateTime.month().year()
        }
    }
}

// MARK: - Metrics helpers

/// Pure derivations over a filtered record set — no view state, so both hosts
/// and every section share one definition of "the numbers".
internal enum CronRunMetrics {
    internal static func filter(_ records: [CronRunRecord], horizon: CronTimeHorizon) -> [CronRunRecord] {
        guard let cutoff = horizon.cutoff else { return records }
        return records.filter { $0.firedAt >= cutoff }
    }

    internal static func jobNames(_ records: [CronRunRecord]) -> [String] {
        Set(records.map { $0.jobName }).sorted()
    }

    internal struct TimeBucket: Identifiable {
        internal let id = UUID()
        internal let start: Date
        internal let okCount: Int
        internal let errorCount: Int
    }

    internal static func aggregatedBuckets(_ records: [CronRunRecord], horizon: CronTimeHorizon) -> [TimeBucket] {
        let cal = Calendar.current
        let component = horizon.bucketComponent
        let grouped = Dictionary(grouping: records) { record in
            cal.dateInterval(of: component, for: record.firedAt)?.start ?? record.firedAt
        }
        return grouped.map { bucketStart, bucketRecords in
            TimeBucket(
                start: bucketStart,
                okCount: bucketRecords.filter { $0.isOk }.count,
                errorCount: bucketRecords.filter { !$0.isOk }.count
            )
        }.sorted { $0.start < $1.start }
    }

    internal static func recordsInBucket(
        _ bucket: TimeBucket, records: [CronRunRecord], horizon: CronTimeHorizon
    ) -> [CronRunRecord] {
        let cal = Calendar.current
        let component = horizon.bucketComponent
        return records.filter { record in
            let bucketStart = cal.dateInterval(of: component, for: record.firedAt)?.start ?? record.firedAt
            return bucketStart == bucket.start
        }.sorted { $0.firedAt > $1.firedAt }
    }
}

// MARK: - Summary tiles

/// Total / OK / Errors / Success-rate chips for the filtered window.
internal struct CronSummaryView: View {
    internal let records: [CronRunRecord]

    internal init(records: [CronRunRecord]) { self.records = records }

    private var total: Int { records.count }
    private var ok: Int { records.filter { $0.isOk }.count }
    private var errors: Int { records.filter { !$0.isOk }.count }
    private var successRate: Double { total > 0 ? Double(ok) / Double(total) * 100 : 0 }

    internal var body: some View {
        HStack(spacing: 0) {
            chip(value: "\(total)", label: "Total", color: Theme.accent)
            chip(value: "\(ok)", label: "OK", color: Theme.success)
            chip(value: "\(errors)", label: "Errors", color: .red)
            chip(
                value: String(format: "%.0f%%", successRate),
                label: "Success",
                color: successRate >= 90 ? Theme.success : successRate >= 50 ? Theme.warning : .red
            )
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.monospacedDigit().bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Volume chart

/// Stacked OK/Error activation volume over time, with a tap-to-inspect popover.
internal struct CronVolumeView: View {
    internal let records: [CronRunRecord]
    internal let horizon: CronTimeHorizon

    @State private var bucketSelection: BucketSelection?
    @State private var selectedRecord: CronRunRecord?

    internal init(records: [CronRunRecord], horizon: CronTimeHorizon) {
        self.records = records
        self.horizon = horizon
    }

    private struct BucketSelection: Identifiable {
        internal let id = UUID()
        internal let records: [CronRunRecord]
    }

    private var buckets: [CronRunMetrics.TimeBucket] {
        CronRunMetrics.aggregatedBuckets(records, horizon: horizon)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activation Volume")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                HStack(spacing: 12) {
                    CronLegendItem(color: Theme.success, label: "OK")
                    CronLegendItem(color: .red, label: "Error")
                }
            }

            if buckets.isEmpty {
                CronEmptyChart()
            } else {
                chart
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var chart: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("Time", bucket.start),
                y: .value("Runs", bucket.okCount)
            )
            .foregroundStyle(by: .value("Status", "OK"))
            .cornerRadius(2)

            if bucket.errorCount > 0 {
                BarMark(
                    x: .value("Time", bucket.start),
                    y: .value("Runs", bucket.errorCount)
                )
                .foregroundStyle(by: .value("Status", "Error"))
                .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale([
            "OK": Theme.success,
            "Error": Color.red
        ])
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisValueLabel(format: horizon.xAxisFormat)
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
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                selectBucket(at: value.startLocation, proxy: proxy, geo: geo)
                            }
                    )
            }
        }
        .frame(minHeight: 160)
        .frame(maxHeight: .infinity)
        .padding(.trailing, 8)
        .popover(item: $bucketSelection) { item in
            CronRunListPopover(
                title: "\(item.records.count) activation(s)",
                records: item.records,
                selectedRecord: $selectedRecord
            )
        }
        .popover(item: $selectedRecord) { record in
            CronSingleRunPopover(record: record)
        }
    }

    private func selectBucket(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { bucketSelection = nil; return }
        guard geo[plotFrame].contains(location) else { bucketSelection = nil; return }
        guard let bucketDate: Date = proxy.value(atX: location.x) else { bucketSelection = nil; return }
        let cal = Calendar.current
        let component = horizon.bucketComponent
        let bucketStart = cal.dateInterval(of: component, for: bucketDate)?.start ?? bucketDate
        guard let match = buckets.first(where: { $0.start == bucketStart }) else {
            bucketSelection = nil
            return
        }
        let recs = CronRunMetrics.recordsInBucket(match, records: records, horizon: horizon)
        bucketSelection = recs.isEmpty ? nil : BucketSelection(records: recs)
    }
}

// MARK: - Jobs list

/// The live jobs list — each an expandable `CronJobCard` with pause/resume/
/// remove/edit actions. Observes the run-history store for per-job stats.
internal struct CronJobsView: View {
    internal var vm: CronListViewModel

    @ObservedObject private var store = CronRunHistoryStore.shared
    @State private var expandedJobID: String?

    internal init(vm: CronListViewModel) { self.vm = vm }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jobs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            if vm.jobs.isEmpty {
                Text("No cron jobs")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(vm.jobs) { job in
                    CronJobCard(
                        job: job,
                        isExpanded: expandedJobID == job.id,
                        runRecords: store.records(for: job.id),
                        onToggle: {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                expandedJobID = expandedJobID == job.id ? nil : job.id
                            }
                        },
                        onPause: { Task { await vm.pauseJob(id: job.id) } },
                        onResume: { Task { await vm.resumeJob(id: job.id) } },
                        onRemove: { Task { await vm.removeJob(id: job.id) } },
                        onUpdatePrompt: { prompt in Task { await vm.updatePrompt(id: job.id, newPrompt: prompt) } }
                    )
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Timeline by job

/// A lane-per-job scatter of activations across the window, tap-to-inspect.
internal struct CronTimelineView: View {
    internal let records: [CronRunRecord]
    internal let horizon: CronTimeHorizon

    @State private var selectedRecord: CronRunRecord?

    internal init(records: [CronRunRecord], horizon: CronTimeHorizon) {
        self.records = records
        self.horizon = horizon
    }

    private var jobNames: [String] { CronRunMetrics.jobNames(records) }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline by Job")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            if records.isEmpty {
                CronEmptyChart()
            } else {
                timelineContent
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var timelineContent: some View {
        let minDate = records.map { $0.firedAt }.min() ?? Date()
        let maxDate = records.map { $0.firedAt }.max() ?? Date()
        let laneHeight: CGFloat = 28
        let dotRadius: CGFloat = 5
        let rightPad: CGFloat = 12
        let totalSpan = maxDate.timeIntervalSince(minDate)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(jobNames, id: \.self) { name in
                        Text(name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 140, height: laneHeight, alignment: .trailing)
                    }
                }
                .padding(.trailing, 10)

                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { geo in
                        let plotWidth = geo.size.width - rightPad
                        ZStack(alignment: .topLeading) {
                            laneLines(count: jobNames.count, laneHeight: laneHeight)

                            ForEach(records) { record in
                                dot(for: record, minDate: minDate, totalSpan: totalSpan,
                                    plotWidth: plotWidth, laneHeight: laneHeight, radius: dotRadius)
                            }
                        }
                    }
                    .frame(height: CGFloat(jobNames.count) * laneHeight)

                    timelineAxis(min: minDate, max: maxDate)
                }
            }
        }
        .popover(item: $selectedRecord) { record in
            CronSingleRunPopover(record: record)
        }
    }

    private func laneLines(count: Int, laneHeight: CGFloat) -> some View {
        Canvas { context, size in
            for i in 0..<count {
                let laneY = CGFloat(i) * laneHeight + laneHeight / 2
                context.stroke(
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: laneY))
                        p.addLine(to: CGPoint(x: size.width, y: laneY))
                    },
                    with: .color(Theme.border.opacity(0.3)),
                    lineWidth: 0.5
                )
            }
        }
    }

    private func dot(
        for record: CronRunRecord, minDate: Date, totalSpan: TimeInterval,
        plotWidth: CGFloat, laneHeight: CGFloat, radius: CGFloat
    ) -> some View {
        let x: CGFloat = totalSpan > 0
            ? CGFloat(record.firedAt.timeIntervalSince(minDate) / totalSpan) * plotWidth
            : plotWidth / 2
        let rowIdx = jobNames.firstIndex(of: record.jobName) ?? 0
        let y = CGFloat(rowIdx) * laneHeight + laneHeight / 2
        return Circle()
            .fill(record.isOk ? Theme.success : Color.red)
            .frame(width: radius * 2, height: radius * 2)
            .position(x: x, y: y)
            .contentShape(Circle().size(width: radius * 4, height: radius * 4))
            .onTapGesture { selectedRecord = record }
    }

    private func timelineAxis(min: Date, max: Date) -> some View {
        let span = max.timeIntervalSince(min)
        let tickCount = 6
        let format = horizon.timelineFormat

        return HStack(spacing: 0) {
            ForEach(0..<tickCount, id: \.self) { i in
                let fraction = span > 0 ? Double(i) / Double(tickCount - 1) : 0
                let date = Date(timeInterval: fraction * span, since: min)
                Text(date, format: format)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: i == 0 ? .leading : i == tickCount - 1 ? .trailing : .center)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Per-job breakdown

/// Per-job OK/Error split bar + success-rate + count, one row per job.
internal struct CronBreakdownView: View {
    internal let records: [CronRunRecord]

    internal init(records: [CronRunRecord]) { self.records = records }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Job Stats")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            if records.isEmpty {
                CronEmptyChart()
            } else {
                let perJob = Dictionary(grouping: records) { $0.jobID }
                ForEach(perJob.keys.sorted(), id: \.self) { jobID in
                    row(jobID: jobID, records: perJob[jobID] ?? [])
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func row(jobID: String, records: [CronRunRecord]) -> some View {
        let name = records.first?.jobName ?? jobID
        let ok = records.filter { $0.isOk }.count
        let err = records.filter { !$0.isOk }.count
        let total = records.count
        let rate = total > 0 ? Double(ok) / Double(total) * 100 : 0

        return HStack(spacing: 12) {
            Text(name)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)

            GeometryReader { geo in
                HStack(spacing: 1) {
                    if ok > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.success)
                            .frame(width: max(2, geo.size.width * CGFloat(ok) / CGFloat(total)))
                    }
                    if err > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.red)
                            .frame(width: max(2, geo.size.width * CGFloat(err) / CGFloat(total)))
                    }
                }
            }
            .frame(height: 10)

            Text(String(format: "%.0f%%", rate))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(rate >= 90 ? Theme.success : rate >= 50 ? Theme.warning : .red)
                .frame(width: 36, alignment: .trailing)

            Text("\(total)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .frame(width: 24, alignment: .trailing)
        }
        .padding(8)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Shared small views

internal struct CronEmptyChart: View {
    internal init() {}

    internal var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title2)
                .foregroundStyle(Theme.tertiary)
            Text("No activations in this time range")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
    }
}

internal struct CronLegendItem: View {
    internal let color: Color
    internal let label: String

    internal init(color: Color, label: String) {
        self.color = color
        self.label = label
    }

    internal var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: - Run detail popovers

internal struct CronRunListPopover: View {
    internal let title: String
    internal let records: [CronRunRecord]
    @Binding internal var selectedRecord: CronRunRecord?

    internal init(title: String, records: [CronRunRecord], selectedRecord: Binding<CronRunRecord?>) {
        self.title = title
        self.records = records
        self._selectedRecord = selectedRecord
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.primary)

            Divider()

            ForEach(records) { record in
                Button {
                    selectedRecord = record
                } label: {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(record.isOk ? Theme.success : Color.red)
                            .frame(width: 6, height: 6)
                        Text(record.firedAt, format: .dateTime.month().day().hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                        Spacer()
                        Text(record.status)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(record.isOk ? Theme.success : .red)
                        if record.duration != nil {
                            Text(record.durationLabel)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                        }
                        if !record.isOk {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 280)
    }
}

internal struct CronSingleRunPopover: View {
    internal let record: CronRunRecord

    internal init(record: CronRunRecord) { self.record = record }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(record.isOk ? Theme.success : Color.red)
                    .frame(width: 8, height: 8)
                Text(record.jobName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }

            Divider()

            detailRow("Status", value: record.status.capitalized)
            detailRow("Fired", value: record.firedAt, format: .dateTime.month().day().hour().minute().second())
            if record.duration != nil {
                detailRow("Duration", value: record.durationLabel)
            }
            detailRow("Job ID", value: String(record.jobID.prefix(12)))

            if !record.isOk {
                errorDetail
            }
        }
        .padding(10)
        .frame(width: 280)
    }

    @ViewBuilder
    private var errorDetail: some View {
        if let msg = record.errorMessage, !msg.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Error")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.red)
                ScrollView {
                    Text(msg)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
            }
            .padding(6)
            .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text("No error detail available — check session logs.")
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.7))
                .padding(.top, 2)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.caption2)
                .foregroundStyle(Theme.primary)
        }
    }

    private func detailRow(_ title: String, value: Date, format: Date.FormatStyle) -> some View {
        HStack {
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
                .frame(width: 60, alignment: .leading)
            Text(value, format: format)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.primary)
        }
    }
}
