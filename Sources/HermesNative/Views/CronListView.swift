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
                    CronJobRow(job: job)
                        #if os(iOS)
                        .swipeActions(edge: .leading) {
                            if job.state == "paused" {
                                Button {
                                    Task { await cronViewModel.resumeJob(id: job.id) }
                                } label: {
                                    Label("Resume", systemImage: "play.fill")
                                }
                                .tint(.green)
                            } else if job.enabled {
                                Button {
                                    Task { await cronViewModel.pauseJob(id: job.id) }
                                } label: {
                                    Label("Pause", systemImage: "pause.fill")
                                }
                                .tint(.orange)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await cronViewModel.removeJob(id: job.id) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
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

#Preview {
    NavigationStack {
        CronListView()
            .environmentObject(GatewayClientWrapper())
    }
}
