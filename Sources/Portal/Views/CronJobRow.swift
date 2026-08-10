import SwiftUI

// One row in the cron list, split out of `CronListView` to keep that file under
// the 800-line limit. Purely presentational — it takes a `CronJob` and renders
// it; every action lives on the list or the detail view.

internal struct CronJobRow: View {
    internal let job: CronJob
    /// In flat mode the full `life/training/morning-run` name is the only place
    /// the category is visible, so it stays. Under the category tree the path is
    /// already the enclosing headers, so the row shows just the leaf title.
    internal var showsCategoryPath: Bool = true

    private var displayName: String {
        CronCategory.displayName(for: job, showingPath: showsCategoryPath)
    }

    internal var body: some View {
        HStack(spacing: 10) {
            statusDot
                .font(.caption)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayName)
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

                if let nextRun = job.nextRunAt {
                    Text("Next: \(nextRun.relativeString)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let preview = job.promptPreview, !preview.isEmpty {
                    Text(preview.truncated(to: 60))
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer()

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
