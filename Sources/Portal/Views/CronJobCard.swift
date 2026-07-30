import Charts
import SwiftUI

// MARK: - Cron Job Card

/// One expandable job row: header (name + schedule + status), and on expand a
/// detail grid, prompt editor, recent runs, and pause/resume/remove actions.
internal struct CronJobCard: View {
    internal let job: CronJob
    internal let isExpanded: Bool
    internal let runRecords: [CronRunRecord]
    internal let onToggle: () -> Void
    internal let onPause: () -> Void
    internal let onResume: () -> Void
    internal let onRemove: () -> Void
    internal let onUpdatePrompt: (String) -> Void

    @State private var isEditingPrompt = false
    @State private var editedPrompt = ""
    @State private var selectedRunRecord: CronRunRecord?
    /// Second-level expansion: a deeper introspection drawer with the execution
    /// timeline and per-run duration plot, distinct from the header tap that
    /// opens the card body.
    @State private var showIntrospection = false

    internal init(
        job: CronJob,
        isExpanded: Bool,
        runRecords: [CronRunRecord],
        onToggle: @escaping () -> Void,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onRemove: @escaping () -> Void,
        onUpdatePrompt: @escaping (String) -> Void
    ) {
        self.job = job
        self.isExpanded = isExpanded
        self.runRecords = runRecords
        self.onToggle = onToggle
        self.onPause = onPause
        self.onResume = onResume
        self.onRemove = onRemove
        self.onUpdatePrompt = onUpdatePrompt
    }

    private var displayJob: CronJob { job }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .contentShape(Rectangle())
                .onTapGesture { onToggle() }

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().background(Theme.border)
                    statsStrip
                    healthBar
                    errorBanner
                    detailRows
                    promptSection
                    recentRuns
                    introspectionSection
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
                    Text(displayJob.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)

                    if !displayJob.schedule.isEmpty {
                        Text(displayJob.schedule)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent.opacity(0.12))
                            .foregroundStyle(Theme.accent)
                            .clipShape(Capsule())
                    }

                    if !displayJob.enabled || displayJob.state == "paused" {
                        Text(displayJob.state == "paused" ? "Paused" : "Disabled")
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
                    if let lastRun = displayJob.lastRunAt {
                        Text("Last: \(lastRun.relativeString)")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    if let status = displayJob.lastStatus {
                        Circle()
                            .fill(status == "ok" ? Theme.success : Color.red)
                            .frame(width: 6, height: 6)
                    }
                    if let nextRun = displayJob.nextRunAt {
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
        if displayJob.state == "paused" || !displayJob.enabled {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
                .font(.body)
        } else if displayJob.lastStatus == "error" {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.body)
        } else if displayJob.lastStatus == "ok" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
                .font(.body)
        } else {
            Image(systemName: "clock.fill")
                .foregroundStyle(Theme.accent)
                .font(.body)
        }
    }

    // MARK: - Derived stats

    private var successRate: Double {
        CronRunHistoryStore.shared.successRate(for: displayJob.id)
    }

    private var failureCount: Int {
        runRecords.filter { !$0.isOk }.count
    }

    private var averageIntervalLabel: String? {
        guard let interval = CronRunHistoryStore.shared.averageInterval(for: displayJob.id),
              interval > 0 else { return nil }
        if interval < 90 { return String(format: "%.0fs", interval) }
        if interval < 5_400 { return String(format: "%.0fm", interval / 60) }
        if interval < 172_800 { return String(format: "%.1fh", interval / 3_600) }
        return String(format: "%.1fd", interval / 86_400)
    }

    /// Compact metric tiles summarizing the job's run health at a glance —
    /// the "informative card" beyond just prompt + recent runs.
    private var statsStrip: some View {
        Group {
            if !runRecords.isEmpty {
                HStack(spacing: 8) {
                    statTile(
                        "Success",
                        value: String(format: "%.0f%%", successRate),
                        tint: successRate >= 80 ? Theme.success : (successRate >= 50 ? Theme.warning : .red)
                    )
                    statTile("Runs", value: "\(runRecords.count)", tint: Theme.accent)
                    statTile(
                        "Failures",
                        value: "\(failureCount)",
                        tint: failureCount == 0 ? Theme.success : .red
                    )
                    if let interval = averageIntervalLabel {
                        statTile("Avg gap", value: interval, tint: Theme.secondary)
                    }
                }
            }
        }
    }

    private func statTile(_ label: String, value: String, tint: Color) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Sparkline-style pass/fail ribbon of the most recent runs (oldest → newest).
    private var healthBar: some View {
        Group {
            if runRecords.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Run health")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.tertiary)
                    HStack(spacing: 2) {
                        let recent = Array(runRecords.suffix(24))
                        ForEach(recent) { record in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(record.isOk ? Theme.success : Color.red)
                                .frame(height: 14)
                                .opacity(record.isOk ? 0.85 : 1)
                        }
                    }
                }
            }
        }
    }

    /// Surface the last failure inline so a broken job is legible without
    /// drilling into a run popover.
    private var errorBanner: some View {
        Group {
            if displayJob.lastStatus == "error", let err = displayJob.lastError, !err.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red.opacity(0.9))
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var detailRows: some View {
        VStack(spacing: 0) {
            detailRow("Job ID", value: displayJob.id)
            detailRow("Schedule", value: displayJob.schedule.isEmpty ? "—" : displayJob.schedule)
            detailRow("State", value: displayJob.state)
            detailRow("Enabled", value: displayJob.enabled ? "Yes" : "No")
            detailRow("Last run", value: displayJob.lastRunAt?.relativeString ?? "Never")
            detailRow("Last status", value: displayJob.lastStatus ?? "—")
            detailRow("Next run", value: displayJob.nextRunAt?.relativeString ?? "—")
            detailRow("Deliver", value: displayJob.deliver.isEmpty ? "—" : displayJob.deliver)
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
                if job.isPromptTruncated {
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(Theme.accent)
                        Text("May be truncated")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }
                }
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
            } else if promptText == "No prompt available" {
                Text(promptText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                MarkdownContentView(text: promptText)
                    .textSelection(.enabled)
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
                .frame(minHeight: 180)
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
        let text = displayJob.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? displayJob.promptPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return text.isEmpty ? "No prompt available" : text
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if displayJob.state == "paused" || !displayJob.enabled {
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

    private var recentRuns: some View {
        Group {
            if !runRecords.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Runs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.primary)

                    let recent = Array(runRecords.suffix(5).reversed())
                    ForEach(recent) { record in
                        Button {
                            selectedRunRecord = record
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(record.isOk ? Theme.success : Color.red)
                                    .frame(width: 6, height: 6)
                                Text(record.firedAt.relativeString)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondary)
                                Text(record.status)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(record.isOk ? Theme.success : .red)
                                if let dur = record.duration {
                                    Text(dur < 60 ? String(format: "%.1fs", dur) : String(format: "%.1fm", dur / 60))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Theme.tertiary)
                                }
                                Spacer()
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
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .popover(item: $selectedRunRecord) { record in
                    CronSingleRunPopover(record: record)
                }
            }
        }
    }

    // MARK: - Second-level introspection

    /// A deeper drawer beneath the card body: an activation-volume chart and a
    /// per-run execution-duration plot, both driven by the real execution
    /// ledger fetched on expand. Collapsed by default so the card stays compact.
    private var introspectionSection: some View {
        Group {
            if !runRecords.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showIntrospection.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showIntrospection ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.tertiary)
                            Text("Introspection")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.primary)
                            Spacer()
                            Text("\(runRecords.count) run\(runRecords.count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showIntrospection {
                        CronVolumeView(records: runRecords, horizon: .week)
                            .frame(height: 200)
                        durationPlot
                    }
                }
                .padding(8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// Per-run wall-clock duration over time — only the runs the ledger has a
    /// measured duration for (started_at → finished_at). Skips the plot when no
    /// run has a duration yet (e.g. store-only records).
    @ViewBuilder
    private var durationPlot: some View {
        let timed = runRecords.filter { $0.duration != nil }.sorted { $0.firedAt < $1.firedAt }
        if timed.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("Execution Time")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.tertiary)
                Chart(timed) { record in
                    LineMark(
                        x: .value("Run", record.firedAt),
                        y: .value("Duration (s)", record.duration ?? 0)
                    )
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.catmullRom)

                    PointMark(
                        x: .value("Run", record.firedAt),
                        y: .value("Duration (s)", record.duration ?? 0)
                    )
                    .foregroundStyle(record.isOk ? Theme.success : Color.red)
                    .symbolSize(30)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
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
                .frame(height: 140)
            }
        }
    }
}
