import SwiftUI

/// Dashboard view for cron jobs — list with status, schedule, and management actions.
struct CronListView: View {
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @State private var cronViewModel = CronListViewModel()

    var body: some View {
        List {
            if cronViewModel.jobs.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
            } else {
                ForEach(cronViewModel.jobs) { job in
                    NavigationLink(value: job) {
                        CronJobRow(job: job)
                    }
                    .contextMenu {
                        cronActions(for: job)
                    }
                    #if os(iOS)
                    .swipeActions(edge: .leading) {
                        pauseResumeButton(for: job)
                    }
                    .swipeActions(edge: .trailing) {
                        removeButton(for: job)
                    }
                    #endif
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .listStyle(.insetGrouped)
        #endif
        .navigationDestination(for: CronJob.self) { job in
            CronJobDetailView(
                job: job,
                onPause: { Task { await cronViewModel.pauseJob(id: job.id) } },
                onResume: { Task { await cronViewModel.resumeJob(id: job.id) } },
                onRemove: { Task { await cronViewModel.removeJob(id: job.id) } }
            )
        }
        .navigationTitle("Cron Jobs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay {
            if cronViewModel.jobs.isEmpty && !cronViewModel.isLoading {
                emptyStateOverlay
            }
        }
        .refreshable {
            await cronViewModel.refreshJobs()
        }
        .task {
            cronViewModel.setGatewayClient(gatewayClientWrapper.client)
            await cronViewModel.refreshJobs()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Cron Jobs")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Cron jobs will appear here when scheduled")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var emptyStateOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.checkmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No Cron Jobs")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Cron jobs will appear here when scheduled")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func cronActions(for job: CronJob) -> some View {
        pauseResumeButton(for: job)
        Divider()
        removeButton(for: job)
    }

    @ViewBuilder
    private func pauseResumeButton(for job: CronJob) -> some View {
        if job.state == "paused" || !job.enabled {
            Button {
                Task { await cronViewModel.resumeJob(id: job.id) }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            #if os(iOS)
            .tint(.green)
            #endif
        } else {
            Button {
                Task { await cronViewModel.pauseJob(id: job.id) }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            #if os(iOS)
            .tint(.orange)
            #endif
        }
    }

    private func removeButton(for job: CronJob) -> some View {
        Button(role: .destructive) {
            Task { await cronViewModel.removeJob(id: job.id) }
        } label: {
            Label("Remove", systemImage: "trash")
        }
    }
}

// MARK: - Cron Job Row

struct CronJobRow: View {
    let job: CronJob

    var body: some View {
        HStack(spacing: 10) {
            // Status dot
            statusDot
                .font(.caption)

            VStack(alignment: .leading, spacing: 3) {
                // Name + schedule badge
                HStack(spacing: 6) {
                    Text(job.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)

                    if !job.schedule.isEmpty {
                        Text(job.schedule)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(scheduleBadgeColor.opacity(0.15))
                            .foregroundStyle(scheduleBadgeColor)
                            .clipShape(Capsule())
                    }
                }

                // Second line: last run + status
                HStack(spacing: 4) {
                    if let lastRun = job.lastRunAt {
                        Text("Last: \(lastRun.relativeString)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let status = job.lastStatus {
                        Circle()
                            .fill(status == "ok" ? Theme.success : Color.red)
                            .frame(width: 6, height: 6)
                    }
                }

                // Third line: next run
                if let nextRun = job.nextRunAt {
                    Text("Next: \(nextRun.relativeString)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // Prompt preview
                if let preview = job.promptPreview, !preview.isEmpty {
                    Text(preview.truncated(to: 60))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Enabled/disabled indicator
            if !job.enabled || job.state == "paused" {
                Text(job.state == "paused" ? "Paused" : "Disabled")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusDot: some View {
        if job.state == "paused" || !job.enabled {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
        } else if job.lastStatus == "error" {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if job.lastStatus == "ok" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        } else {
            Image(systemName: "clock.fill")
                .foregroundStyle(Theme.accent)
        }
    }

    private var scheduleBadgeColor: Color {
        job.enabled ? Theme.accent : .secondary
    }
}

// MARK: - Cron Job Detail

struct CronJobDetailView: View {
    let job: CronJob
    let onPause: () -> Void
    let onResume: () -> Void
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isPromptExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                detailCard
                promptCard
                actionButtons
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Theme.background)
        .navigationTitle(job.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .font(.title2)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 6) {
                Text(job.name)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Text(job.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
    }

    private var detailCard: some View {
        VStack(spacing: 0) {
            detailRow("Schedule", value: job.schedule.isEmpty ? "—" : job.schedule)
            detailRow("State", value: job.state)
            detailRow("Enabled", value: job.enabled ? "Yes" : "No")
            detailRow("Last run", value: job.lastRunAt?.relativeString ?? "Never")
            detailRow("Last status", value: job.lastStatus ?? "—")
            detailRow("Next run", value: job.nextRunAt?.relativeString ?? "—")
            detailRow("Deliver", value: job.deliver.isEmpty ? "—" : job.deliver)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var promptCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Prompt")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                if isPromptExpandable {
                    Button(isPromptExpanded ? "Collapse" : "Expand") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isPromptExpanded.toggle()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            ScrollView(isPromptExpanded ? [.vertical] : []) {
                Text(promptText)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .lineLimit(isPromptExpanded ? nil : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: isPromptExpanded ? 420 : nil, alignment: .top)

            if isPromptExpandable && !isPromptExpanded {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isPromptExpanded = true
                    }
                } label: {
                    Label("Read full prompt", systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .font(.caption)
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private var promptText: String {
        let text = job.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? job.promptPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""
        return text.isEmpty ? "No prompt available" : text
    }

    private var isPromptExpandable: Bool {
        promptText.count > 400 || promptText.contains("\n")
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if job.state == "paused" || !job.enabled {
                Button {
                    onResume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    onPause()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            }

            Button(role: .destructive) {
                onRemove()
                dismiss()
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.6))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if job.state == "paused" || !job.enabled {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(.secondary)
        } else if job.lastStatus == "error" {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        } else if job.lastStatus == "ok" {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        } else {
            Image(systemName: "clock.fill")
                .foregroundStyle(Theme.accent)
        }
    }
}

#Preview {
    NavigationStack {
        CronListView()
            .environmentObject(GatewayClientWrapper())
    }
}
