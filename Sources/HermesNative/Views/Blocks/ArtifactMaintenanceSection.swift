import SwiftUI

// MARK: - Environment plumbing

/// Optional "open the cron surface, focused on this job" action. The artifact
/// maintenance section reads it to make a maintainer row tappable; when absent
/// (previews, PDF export, contexts with no cron surface) the rows render but
/// don't navigate — an environment VALUE, not an EnvironmentObject, so absence
/// is a graceful no-op. Mirrors `openArtifact`.
private struct OpenCronKey: EnvironmentKey {
    static let defaultValue: (@MainActor (String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Navigate to the cron surface; the String is the target job id (empty =
    /// just open the list).
    var openCron: (@MainActor (String) -> Void)? {
        get { self[OpenCronKey.self] }
        set { self[OpenCronKey.self] = newValue }
    }
}

// MARK: - Maintenance section

/// The "is this artifact actually being kept current?" surface for the artifact
/// detail pane. Every living artifact is mutable, but only those with a
/// maintaining cron are *tended*; this section makes that difference legible:
/// - Maintainers declared → each resolved cron with its schedule, next run, and
///   last status, tappable through to the cron surface.
/// - A declared cron that no longer exists → shown as "missing" so a broken
///   link is visible, not silent.
/// - None declared → a quiet "Not on a schedule" line, with a link affordance
///   on JSON artifacts so a human can attach the maintaining cron.
struct ArtifactMaintenanceSection: View {
    let artifact: LivingArtifact
    /// All known cron jobs (from CronListViewModel), used to resolve refs.
    let jobs: [CronJob]
    @Environment(\.openCron) private var openCron
    @ObservedObject private var store = ArtifactStore.shared

    @State private var isLinking = false

    private var refs: [MaintainerRef] { artifact.maintainerRefs }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if refs.isEmpty {
                unmaintainedRow
            } else {
                ForEach(refs) { ref in
                    maintainerRow(ref)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(refs.isEmpty ? Theme.tertiary : Theme.accent)
            Text("Maintenance")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Spacer()
            if artifact.supportsMaintainers {
                linkMenu
            }
        }
    }

    // MARK: Rows

    private var unmaintainedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
            Text("Not on a schedule — mutable, but nothing keeps it current.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
        }
    }

    @ViewBuilder
    private func maintainerRow(_ ref: MaintainerRef) -> some View {
        switch ref {
        case .cron(let jobID):
            if let job = jobs.first(where: { $0.id == jobID }) {
                cronRow(job: job, ref: ref)
            } else {
                missingRow(label: jobID, ref: ref)
            }
        case .other(let type, let value):
            missingRow(label: "\(type): \(value)", ref: ref, isUnknownKind: true)
        }
    }

    private func cronRow(job: CronJob, ref: MaintainerRef) -> some View {
        Button {
            openCron?(job.id)
        } label: {
            HStack(spacing: 8) {
                statusDot(for: job)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(job.name)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        if !job.schedule.isEmpty {
                            Text(job.schedule)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                        if !job.enabled || job.state == "paused" {
                            Text(job.state == "paused" ? "Paused" : "Disabled")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Theme.warning)
                        }
                    }
                    Text(subtitle(for: job))
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if openCron != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                removeButton(ref)
            }
        }
        .buttonStyle(.plain)
        .disabled(openCron == nil)
    }

    /// A declared maintainer that doesn't resolve to a known cron — a broken or
    /// not-yet-loaded link. Shown rather than hidden so it's fixable.
    private func missingRow(label: String, ref: MaintainerRef, isUnknownKind: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isUnknownKind ? "questionmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 12, design: isUnknownKind ? .default : .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                Text(isUnknownKind ? "Unrecognized maintainer" : "Cron not found — it may be removed or not yet loaded")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            Spacer(minLength: 4)
            removeButton(ref)
        }
    }

    private func removeButton(_ ref: MaintainerRef) -> some View {
        Button {
            store.setMaintainers(artifactID: artifact.id, refs: refs.filter { $0 != ref })
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        }
        .buttonStyle(.plain)
        .help("Unlink this maintainer")
    }

    // MARK: Link menu

    @ViewBuilder
    private var linkMenu: some View {
        let linkable = jobs.filter { job in !refs.contains(.cron(jobID: job.id)) }
        Menu {
            if linkable.isEmpty {
                Text("No other cron jobs to link")
            } else {
                ForEach(linkable) { job in
                    Button {
                        store.setMaintainers(
                            artifactID: artifact.id,
                            refs: refs + [.cron(jobID: job.id)]
                        )
                    } label: {
                        Label(job.name, systemImage: "clock.arrow.circlepath")
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Link a cron job that maintains this artifact")
    }

    // MARK: Presentation helpers

    @ViewBuilder
    private func statusDot(for job: CronJob) -> some View {
        if job.state == "paused" || !job.enabled {
            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.secondary)
        } else if job.lastStatus == "error" {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        } else if job.lastStatus == "ok" {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        } else {
            Image(systemName: "clock.fill").foregroundStyle(Theme.accent)
        }
    }

    private func subtitle(for job: CronJob) -> String {
        var parts: [String] = []
        if let last = job.lastRunAt { parts.append("Last \(last.relativeString)") }
        if let next = job.nextRunAt, job.enabled, job.state != "paused" {
            parts.append("next \(next.relativeString)")
        }
        return parts.isEmpty ? "No runs recorded yet" : parts.joined(separator: " · ")
    }
}
