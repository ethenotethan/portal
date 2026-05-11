import SwiftUI
import Charts

struct CronDashboardView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @ObservedObject var store: CronRunHistoryStore = .shared
    @State private var cronListVM = CronListViewModel()
    @State private var timeHorizon: TimeHorizon = .day
    @State private var expandedJobID: String?

    enum TimeHorizon: String, CaseIterable {
        case hour = "1h"
        case day = "24h"
        case week = "7d"
        case month = "30d"
        case all = "All"

        var cutoff: Date? {
            switch self {
            case .hour: return Calendar.current.date(byAdding: .hour, value: -1, to: Date())
            case .day: return Calendar.current.date(byAdding: .hour, value: -24, to: Date())
            case .week: return Calendar.current.date(byAdding: .day, value: -7, to: Date())
            case .month: return Calendar.current.date(byAdding: .day, value: -30, to: Date())
            case .all: return nil
            }
        }

        var bucketComponent: Calendar.Component {
            switch self {
            case .hour: return .minute
            case .day: return .hour
            case .week: return .hour
            case .month: return .day
            case .all: return .day
            }
        }

        var xAxisFormat: Date.FormatStyle {
            switch self {
            case .hour: return .dateTime.hour().minute()
            case .day: return .dateTime.hour()
            case .week: return .dateTime.weekday().hour()
            case .month: return .dateTime.day().month()
            case .all: return .dateTime.month().year()
            }
        }

        var timelineFormat: Date.FormatStyle {
            switch self {
            case .hour: return .dateTime.hour().minute()
            case .day: return .dateTime.hour().minute()
            case .week: return .dateTime.weekday().hour()
            case .month: return .dateTime.day().month()
            case .all: return .dateTime.month().year()
            }
        }
    }

    private struct TimeBucket: Identifiable {
        let id = UUID()
        let start: Date
        let okCount: Int
        let errorCount: Int
        let jobName: String
    }

    private var filteredRecords: [CronRunRecord] {
        let all = store.allRecordsSorted()
        guard let cutoff = timeHorizon.cutoff else { return all }
        return all.filter { $0.firedAt >= cutoff }
    }

    private var jobNames: [String] {
        let names = Set(filteredRecords.map { $0.jobName })
        return names.sorted()
    }

    private var aggregatedBuckets: [TimeBucket] {
        let cal = Calendar.current
        let component = timeHorizon.bucketComponent

        var result: [TimeBucket] = []
        let grouped = Dictionary(grouping: filteredRecords) { record in
            cal.dateInterval(of: component, for: record.firedAt)?.start ?? record.firedAt
        }

        for (bucketStart, records) in grouped {
            result.append(TimeBucket(
                start: bucketStart,
                okCount: records.filter { $0.isOk }.count,
                errorCount: records.filter { !$0.isOk }.count,
                jobName: "All"
            ))
        }

        return result.sorted { $0.start < $1.start }
    }

    private var totalRuns: Int { filteredRecords.count }
    private var okRuns: Int { filteredRecords.filter { $0.isOk }.count }
    private var errorRuns: Int { filteredRecords.filter { !$0.isOk }.count }
    private var successRate: Double { totalRuns > 0 ? Double(okRuns) / Double(totalRuns) * 100 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider().background(Theme.border)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    summaryCards
                    volumeChart
                    if !cronListVM.jobs.isEmpty {
                        jobsSection
                    }
                    if !filteredRecords.isEmpty {
                        perJobTimeline
                        perJobBreakdown
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .refreshable { await refreshData() }
        }
        .background(Theme.background)
        .task { await refreshData() }
    }

    private func refreshData() async {
        cronListVM.setGatewayClient(gatewayClientWrapper.client)
        await cronListVM.refreshJobs()
        store.seedFromJobs(cronListVM.jobs)
        store.detectNewRuns(from: cronListVM.jobs)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text("Cron Activity")
                .font(.headline)
                .foregroundStyle(Theme.primary)

            Spacer()

            Picker("", selection: $timeHorizon) {
                ForEach(TimeHorizon.allCases, id: \.self) { h in
                    Text(h.rawValue).tag(h)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    // MARK: - Summary

    private var summaryCards: some View {
        HStack(spacing: 0) {
            summaryChip(value: "\(totalRuns)", label: "Total", color: Theme.accent)
            summaryChip(value: "\(okRuns)", label: "OK", color: Theme.success)
            summaryChip(value: "\(errorRuns)", label: "Errors", color: .red)
            summaryChip(
                value: String(format: "%.0f%%", successRate),
                label: "Success",
                color: successRate >= 90 ? Theme.success : successRate >= 50 ? Theme.warning : .red
            )
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func summaryChip(value: String, label: String, color: Color) -> some View {
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

    // MARK: - Volume Chart

    private var volumeChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activation Volume")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                HStack(spacing: 12) {
                    LegendItem(color: Theme.success, label: "OK")
                    LegendItem(color: .red, label: "Error")
                }
            }

            if aggregatedBuckets.isEmpty {
                emptyChart
            } else {
                Chart {
                    ForEach(aggregatedBuckets) { bucket in
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
                }
                .chartForegroundStyleScale([
                    "OK": Theme.success,
                    "Error": Color.red
                ])
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 8)) { value in
                        AxisValueLabel(format: timeHorizon.xAxisFormat)
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
                .frame(height: 200)
                .padding(.trailing, 8)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Jobs Section

    private var jobsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Jobs")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            ForEach(cronListVM.jobs) { job in
                CronJobCard(
                    job: job,
                    isExpanded: expandedJobID == job.id,
                    runRecords: store.records(for: job.id),
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            expandedJobID = expandedJobID == job.id ? nil : job.id
                        }
                    },
                    onPause: { Task { await cronListVM.pauseJob(id: job.id) } },
                    onResume: { Task { await cronListVM.resumeJob(id: job.id) } },
                    onRemove: { Task { await cronListVM.removeJob(id: job.id) } },
                    onUpdatePrompt: { prompt in Task { await cronListVM.updatePrompt(id: job.id, newPrompt: prompt) } }
                )
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Per-Job Timeline

    private var perJobTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Timeline by Job")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            if filteredRecords.isEmpty {
                emptyChart
            } else {
                timelineContent
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var timelineContent: some View {
        let minDate = filteredRecords.map { $0.firedAt }.min() ?? Date()
        let maxDate = filteredRecords.map { $0.firedAt }.max() ?? Date()

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(jobNames, id: \.self) { name in
                        Text(name)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 140, height: 28, alignment: .trailing)
                    }
                }
                .padding(.trailing, 10)

                VStack(alignment: .leading, spacing: 0) {
                    Canvas { context, size in
                        let laneHeight: CGFloat = 28
                        let dotRadius: CGFloat = 5
                        let rightPad: CGFloat = 12

                        for (i, name) in jobNames.enumerated() {
                            let laneY = CGFloat(i) * laneHeight + laneHeight / 2

                            context.stroke(
                                Path { p in
                                    p.move(to: CGPoint(x: 0, y: laneY))
                                    p.addLine(to: CGPoint(x: size.width, y: laneY))
                                },
                                with: .color(Theme.border.opacity(0.3)),
                                lineWidth: 0.5
                            )

                            let jobRecords = filteredRecords.filter { $0.jobName == name }
                            let totalSpan = maxDate.timeIntervalSince(minDate)

                            for record in jobRecords {
                                let x: CGFloat
                                if totalSpan > 0 {
                                    let xRatio = record.firedAt.timeIntervalSince(minDate) / totalSpan
                                    x = CGFloat(xRatio) * (size.width - rightPad)
                                } else {
                                    x = size.width / 2
                                }

                                let rect = CGRect(
                                    x: x - dotRadius,
                                    y: laneY - dotRadius,
                                    width: dotRadius * 2,
                                    height: dotRadius * 2
                                )
                                context.fill(
                                    Path(ellipseIn: rect),
                                    with: .color(record.isOk ? Theme.success : Color.red)
                                )
                            }
                        }
                    }
                    .frame(height: CGFloat(jobNames.count) * 28)

                    timelineAxis(min: minDate, max: maxDate)
                }
            }
        }
    }

    private func timelineAxis(min: Date, max: Date) -> some View {
        let span = max.timeIntervalSince(min)
        let tickCount = 6
        let format = timeHorizon.timelineFormat

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

    // MARK: - Per-Job Breakdown

    private var perJobBreakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Per-Job Stats")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)

            let perJob = Dictionary(grouping: filteredRecords) { $0.jobID }
            ForEach(perJob.keys.sorted(), id: \.self) { jobID in
                let records = perJob[jobID] ?? []
                let name = records.first?.jobName ?? jobID
                let ok = records.filter { $0.isOk }.count
                let err = records.filter { !$0.isOk }.count
                let total = records.count
                let rate = total > 0 ? Double(ok) / Double(total) * 100 : 0

                HStack(spacing: 12) {
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
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyChart: some View {
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

// MARK: - Cron Job Card

private struct CronJobCard: View {
    let job: CronJob
    let isExpanded: Bool
    let runRecords: [CronRunRecord]
    let onToggle: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void
    let onUpdatePrompt: (String) -> Void

    @State private var isEditingPrompt = false
    @State private var editedPrompt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().background(Theme.border)
                    detailRows
                    promptSection
                    recentRuns
                    actionButtons
                }
                .padding(.top, 8)
                .padding(.leading, 28)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
        }
        .padding(10)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: chevronName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 14)

            statusDot

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(job.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    if !job.schedule.isEmpty {
                        Text(job.schedule)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12))
                            .foregroundStyle(Theme.accent)
                            .clipShape(Capsule())
                    }

                    if !job.enabled || job.state == "paused" {
                        Text(job.state == "paused" ? "Paused" : "Disabled")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                }

                HStack(spacing: 8) {
                    if let lastRun = job.lastRunAt {
                        Text("Last: \(lastRun.relativeString)")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    if let status = job.lastStatus {
                        Circle()
                            .fill(status == "ok" ? Theme.success : Color.red)
                            .frame(width: 6, height: 6)
                    }
                    if let nextRun = job.nextRunAt {
                        Text("Next: \(nextRun.relativeString)")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            Spacer()
        }
    }

    private var chevronName: String {
        isExpanded ? "chevron.down" : "chevron.right"
    }

    @ViewBuilder
    private var statusDot: some View {
        if job.state == "paused" || !job.enabled {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .font(.body)
        } else if job.lastStatus == "error" {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.body)
        } else if job.lastStatus == "ok" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .font(.body)
        } else {
            Image(systemName: "clock.fill")
                .foregroundStyle(Theme.accent)
                .font(.body)
        }
    }

    private var detailRows: some View {
        VStack(spacing: 0) {
            detailRow("Job ID", value: job.id)
            detailRow("Schedule", value: job.schedule.isEmpty ? "—" : job.schedule)
            detailRow("State", value: job.state)
            detailRow("Enabled", value: job.enabled ? "Yes" : "No")
            detailRow("Last run", value: job.lastRunAt?.relativeString ?? "Never")
            detailRow("Last status", value: job.lastStatus ?? "—")
            detailRow("Next run", value: job.nextRunAt?.relativeString ?? "—")
            detailRow("Deliver", value: job.deliver.isEmpty ? "—" : job.deliver)
            if !runRecords.isEmpty {
                let rate = CronRunHistoryStore.shared.successRate(for: job.id)
                detailRow("Success rate", value: String(format: "%.0f%% (%d runs)", rate, runRecords.count))
            }
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                if !isEditingPrompt {
                    Button {
                        editedPrompt = promptText
                        isEditingPrompt = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isEditingPrompt {
                promptEditor
            } else {
                Text(promptText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var promptEditor: some View {
        VStack(spacing: 8) {
            TextEditor(text: $editedPrompt)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .scrollContentBackground(.hidden)
                .background(Theme.background)
                .frame(minHeight: 120, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Theme.border, lineWidth: 1)
                )

            HStack {
                Spacer()
                Button("Cancel") {
                    isEditingPrompt = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Save") {
                    onUpdatePrompt(editedPrompt)
                    isEditingPrompt = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(editedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var promptText: String {
        let text = job.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? job.promptPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return text.isEmpty ? "No prompt available" : text
    }

    private var recentRuns: some View {
        Group {
            if !runRecords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Runs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.primary)

                    let recent = Array(runRecords.suffix(5).reversed())
                    ForEach(recent) { record in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(record.isOk ? Theme.success : Color.red)
                                .frame(width: 6, height: 6)
                            Text(record.firedAt.relativeString)
                                .font(.caption2)
                                .foregroundStyle(Theme.secondary)
                            Text(record.status)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.tertiary)
                            if let dur = record.duration {
                                Text(dur < 60 ? String(format: "%.1fs", dur) : String(format: "%.1fm", dur / 60))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if job.state == "paused" || !job.enabled {
                Button {
                    onResume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button {
                    onPause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String

    var body: some View {
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
