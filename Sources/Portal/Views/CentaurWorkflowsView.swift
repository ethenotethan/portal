import SwiftUI
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CentaurWorkflows")

/// Centaur workflow introspection — the Centaur analogue of the Hermes cron
/// dashboard, organized the way operators actually read automation: one row
/// per WORKFLOW (GitHub-Actions style), not a flat run list.
///
/// Each row: name, cadence, enabled state, a recent-run strip (oldest→newest
/// colored cells), last-run recency, and quick health. Rows expand to the
/// run history; runs open a detail sheet with payloads. A header strip
/// summarizes deployment health at a glance. Auto-refreshes while visible
/// (15s) so pending/running runs move without hand-refreshing.
struct CentaurWorkflowsView: View {
    let client: CentaurClient
    var onClose: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var schedules: [CentaurWorkflowSchedule] = []
    @State private var runs: [CentaurWorkflowRun] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var cancellingRunIDs: Set<String> = []
    @State private var selectedRun: CentaurWorkflowRun?
    @State private var expandedWorkflows: Set<String> = []

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Theme.border)
                content
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .task { await load(initial: true) }
        .task {
            // Quiet auto-refresh while visible; pending → running → completed
            // transitions appear without user action.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await load(initial: false)
            }
        }
        .sheet(item: $selectedRun) { run in
            RunDetailSheet(run: run)
        }
    }

    // MARK: - Grouping

    /// One entry per workflow: its schedule (if registered), its runs
    /// (newest first), sorted by most recent activity.
    private var groups: [WorkflowGroup] {
        var byName: [String: WorkflowGroup] = [:]
        for schedule in schedules {
            byName[schedule.workflowName] = WorkflowGroup(
                name: schedule.workflowName, schedule: schedule, runs: []
            )
        }
        for run in runs {
            byName[run.workflowName, default: WorkflowGroup(name: run.workflowName, schedule: nil, runs: [])]
                .runs.append(run)
        }
        for name in byName.keys {
            byName[name]?.runs.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        }
        return byName.values.sorted { lhs, rhs in
            // Active first, then most recent activity, then name.
            if lhs.hasActiveRun != rhs.hasActiveRun { return lhs.hasActiveRun }
            let l = lhs.lastActivity ?? .distantPast
            let r = rhs.lastActivity ?? .distantPast
            if l != r { return l > r }
            return lhs.name < rhs.name
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text("Workflows")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primary)
            if !isLoading, loadError == nil {
                healthSummary
            }
            Spacer()
            Button {
                Task { await load(initial: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh now (auto-refreshes every 15s)")
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 26, height: 26)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// At-a-glance deployment health: active / recent-failure / total counts.
    private var healthSummary: some View {
        let active = runs.filter(\.isActive).count
        let failed = runs.filter { $0.status.lowercased() == "failed" }.count
        return HStack(spacing: 8) {
            if active > 0 {
                summaryPill("\(active) active", color: Theme.accent, pulse: true)
            }
            if failed > 0 {
                summaryPill("\(failed) failed", color: .red, pulse: false)
            }
            summaryPill("\(schedules.filter(\.enabled).count)/\(schedules.count) scheduled", color: Theme.secondary, pulse: false)
        }
        .padding(.leading, 6)
    }

    private func summaryPill(_ text: String, color: Color, pulse: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .modifier(PulseEffect(active: pulse))
            Text(text)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.surfaceHover.opacity(0.6), in: Capsule())
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            VStack(spacing: 10) {
                PortalProgressView()
                Text("Loading workflows…")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await load(initial: true) } }
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.tertiary)
                Text("No workflows")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text("This Centaur deployment has no registered schedules or recorded runs — or its workflow runtime is disabled.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CentaurWorkflowActivityChart(runs: runs)
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(groups) { group in
                            WorkflowGroupRow(
                                group: group,
                                isExpanded: expandedWorkflows.contains(group.name),
                                cancellingRunIDs: cancellingRunIDs,
                                onToggle: { toggleExpanded(group.name) },
                                onSelectRun: { selectedRun = $0 },
                                onCancelRun: { run in Task { await cancel(run) } }
                            )
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func toggleExpanded(_ name: String) {
        withAnimation(.easeInOut(duration: 0.15)) {
            if expandedWorkflows.contains(name) {
                expandedWorkflows.remove(name)
            } else {
                expandedWorkflows.insert(name)
            }
        }
    }

    // MARK: - Data

    private func load(initial: Bool) async {
        if initial {
            isLoading = runs.isEmpty && schedules.isEmpty
            loadError = nil
        }
        do {
            async let fetchedSchedules = client.workflowSchedules()
            async let fetchedRuns = client.workflowRuns(limit: 100)
            schedules = try await fetchedSchedules
            runs = try await fetchedRuns
            loadError = nil
        } catch {
            // Background refresh failures keep showing the last good data.
            if initial {
                log.error("workflow load failed: \(error.localizedDescription)")
                loadError = "Couldn't load workflows: \(error.localizedDescription)"
            }
        }
        isLoading = false
    }

    private func cancel(_ run: CentaurWorkflowRun) async {
        cancellingRunIDs.insert(run.runID)
        defer { cancellingRunIDs.remove(run.runID) }
        do {
            try await client.cancelWorkflowRun(runID: run.runID)
            await load(initial: false)
        } catch {
            loadError = "Cancel failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Group model

private struct WorkflowGroup: Identifiable {
    let name: String
    var schedule: CentaurWorkflowSchedule?
    var runs: [CentaurWorkflowRun]

    var id: String { name }
    var hasActiveRun: Bool { runs.contains(where: \.isActive) }
    var lastActivity: Date? { runs.first?.createdAt }
    var lastFailure: CentaurWorkflowRun? {
        runs.first { $0.status.lowercased() == "failed" }
    }
}

// MARK: - Workflow row

private struct WorkflowGroupRow: View {
    let group: WorkflowGroup
    let isExpanded: Bool
    let cancellingRunIDs: Set<String>
    let onToggle: () -> Void
    let onSelectRun: (CentaurWorkflowRun) -> Void
    let onCancelRun: (CentaurWorkflowRun) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryRow
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
            if isExpanded {
                Divider().overlay(Theme.border.opacity(0.5))
                runList
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(group.hasActiveRun ? Theme.accent.opacity(0.4) : Theme.border, lineWidth: 0.5)
        )
    }

    private var summaryRow: some View {
        HStack(spacing: 12) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                    if let schedule = group.schedule {
                        Text(schedule.kindLabel)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Theme.surfaceHover, in: Capsule())
                        if !schedule.enabled {
                            Text("disabled")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                HStack(spacing: 6) {
                    if let last = group.lastActivity {
                        Text("last run \(last.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    } else {
                        Text("no runs recorded")
                            .font(.caption2)
                            .foregroundStyle(Theme.tertiary)
                    }
                    if let failure = group.lastFailure, let summary = failure.failureSummary {
                        Text("· \(summary)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 12)

            RunStrip(runs: Array(group.runs.prefix(14).reversed()), onSelect: onSelectRun)

            statusGlyph
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Rightmost glyph: live spinner when active, else health of latest run.
    @ViewBuilder
    private var statusGlyph: some View {
        if group.hasActiveRun {
            PortalProgressView()
                .scaleEffect(0.55)
                .frame(width: 18)
        } else if let latest = group.runs.first {
            Image(systemName: latest.status.lowercased() == "failed"
                  ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(latest.status.lowercased() == "failed" ? .red : .green)
                .frame(width: 18)
        } else {
            Image(systemName: "minus.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 18)
        }
    }

    private var runList: some View {
        VStack(spacing: 0) {
            ForEach(group.runs.prefix(20)) { run in
                RunRow(
                    run: run,
                    isCancelling: cancellingRunIDs.contains(run.runID),
                    onCancel: { onCancelRun(run) },
                    onSelect: { onSelectRun(run) }
                )
                if run.id != group.runs.prefix(20).last?.id {
                    Divider().overlay(Theme.border.opacity(0.3))
                }
            }
        }
    }
}

// MARK: - Run strip

/// GitHub-Actions-style recent-run cells, oldest → newest. Color = outcome;
/// active runs pulse. Each cell is hoverable (tooltip) and clickable.
private struct RunStrip: View {
    let runs: [CentaurWorkflowRun]
    let onSelect: (CentaurWorkflowRun) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(runs) { run in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(for: run))
                    .frame(width: 7, height: 18)
                    .modifier(PulseEffect(active: run.isActive))
                    .onTapGesture { onSelect(run) }
                    .help(stripHelp(run))
            }
        }
    }

    private func color(for run: CentaurWorkflowRun) -> Color {
        switch run.status.lowercased() {
        case "completed": return .green.opacity(0.75)
        case "failed": return .red
        case "cancelled", "canceled": return .orange.opacity(0.8)
        case "running", "in_progress", "active": return Theme.accent
        case "pending", "queued": return Theme.tertiary
        default: return Theme.tertiary.opacity(0.5)
        }
    }

    private func stripHelp(_ run: CentaurWorkflowRun) -> String {
        var parts = [run.status]
        if let created = run.createdAt {
            parts.append(created.formatted(date: .abbreviated, time: .shortened))
        }
        if let failure = run.failureSummary { parts.append(failure) }
        return parts.joined(separator: " · ")
    }
}

/// Gentle opacity pulse for live indicators.
private struct PulseEffect: ViewModifier {
    let active: Bool
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .opacity(active && dim ? 0.35 : 1)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { if active { dim = true } }
            .onChange(of: active) { _, nowActive in dim = nowActive }
    }
}

// MARK: - Run row (expanded)

private struct RunRow: View {
    let run: CentaurWorkflowRun
    let isCancelling: Bool
    let onCancel: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            statusBadge
            if let created = run.createdAt {
                Text(created.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
            }
            if let duration = durationLabel {
                Text(duration)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            if run.attempts > 1 {
                Text("\(run.attempts) attempts")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let failure = run.failureSummary {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Spacer()
            if run.isActive {
                Button(isCancelling ? "Cancelling…" : "Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCancelling)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    /// created→updated as a rough duration for terminal runs.
    private var durationLabel: String? {
        guard !run.isActive,
              let created = run.createdAt, let updated = run.updatedAt,
              updated > created else { return nil }
        let seconds = Int(updated.timeIntervalSince(created))
        guard seconds >= 1 else { return nil }
        return Duration.seconds(seconds).formatted(.units(width: .narrow, maximumUnitCount: 2))
    }

    private var statusBadge: some View {
        Text(run.status)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.14), in: Capsule())
            .frame(minWidth: 74, alignment: .leading)
    }

    private var statusColor: Color {
        switch run.status.lowercased() {
        case "completed": return .green
        case "failed": return .red
        case "cancelled", "canceled": return .orange
        case "running", "in_progress", "active": return Theme.accent
        default: return Theme.secondary
        }
    }
}

// MARK: - Run detail

private struct RunDetailSheet: View {
    let run: CentaurWorkflowRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(run.workflowName)
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button("Done") { dismiss() }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                detailRow("Run ID", run.runID)
                detailRow("Status", run.status)
                detailRow("Attempts", "\(run.attempts)")
                if let created = run.createdAt {
                    detailRow("Created", created.formatted(date: .abbreviated, time: .standard))
                }
                if let updated = run.updatedAt {
                    detailRow("Updated", updated.formatted(date: .abbreviated, time: .standard))
                }
            }
            if let input = run.input {
                payloadSection("Input", value: input)
            }
            if let result = run.result {
                payloadSection("Result", value: result)
            }
            if let failure = run.failure {
                payloadSection("Failure", value: failure)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 320)
        .background(Theme.background)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
        }
    }

    private func payloadSection(_ title: String, value: AnyCodable) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            ScrollView {
                Text(value.displayString)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
            .padding(8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
