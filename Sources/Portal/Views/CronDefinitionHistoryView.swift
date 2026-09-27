import SwiftUI

/// When a cron job's *definition* changed — prompt, model, schedule, skills,
/// script, delivery — as the harness recorded it, newest first. Distinct from
/// the recent runs on the same card (when it *fired*) and from the Revisions
/// drawer on the dataflow surface (when the *graph* moved). Each row names the
/// fields that changed; tapping one unfolds their before and after values.
///
/// `result` is nil while the list is still fetching, `.unsupported` on a gateway
/// without the `revisions` action (an older harness), `.failed` on a transport
/// error, else the page.
internal struct CronDefinitionHistoryView: View {
    internal let result: CronJobRevisionsResult?

    /// Which revision's field changes are unfolded.
    @State private var expandedRevisionID: String?

    internal init(result: CronJobRevisionsResult?) {
        self.result = result
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let shown = 6

    /// When the job's *definition* changed — prompt, model, schedule, skills,
    /// script, delivery — as the harness recorded it, newest first. Distinct from
    /// the recent runs (when it *fired*) and from the Revisions drawer on the
    /// dataflow surface (when the *graph* moved). Each row names the fields that
    /// changed; tapping one unfolds their before and after values.
    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Definition history")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                if case .loaded(let page) = result ?? .failed, page.total > 0 {
                    Text("\(page.total) revision\(page.total == 1 ? "" : "s")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            switch result {
            case .none:
                Text("Loading…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            case .unsupported:
                Text("This gateway does not record job definitions yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            case .failed:
                Text("Definition history could not be loaded.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
            case .loaded(let page):
                if page.revisions.isEmpty {
                    Text("No recorded changes to this job's definition.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(page.revisions.prefix(Self.shown)) { revision in
                            revisionRow(revision)
                        }
                        if page.total > Self.shown {
                            Text("\(page.total - Self.shown) earlier revision\(page.total - Self.shown == 1 ? "" : "s") not shown")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func revisionRow(_ revision: CronJobRevision) -> some View {
        let isOpen = expandedRevisionID == revision.id
        let when = revision.date.map(Self.formatter.string(from:)) ?? "time not recorded"
        let fields = revision.changedFields
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedRevisionID = isOpen ? nil : revision.id
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(revision.action.isEmpty ? "change" : revision.action)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(revision.action == "delete" ? Theme.warning : Theme.accent)
                        .textCase(.uppercase)
                    Text(when)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                    Image(systemName: revision.actor.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.tertiary)
                    Text(revision.actor.label)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 4)
                    if !revision.definitionRecorded {
                        Text("definition not recorded")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.tertiary)
                    } else if !fields.isEmpty {
                        Text(fields.joined(separator: ", "))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                    }
                    if !revision.changes.isEmpty {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(revision.action) \(when): \(fields.joined(separator: ", "))")
            if isOpen {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(revision.changes.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(change.field)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.secondary)
                            HStack(alignment: .top, spacing: 6) {
                                Text(change.beforeText)
                                    .strikethrough(change.before != nil)
                                    .foregroundStyle(Theme.tertiary)
                                Text("→")
                                    .foregroundStyle(Theme.tertiary)
                                Text(change.afterText)
                                    .foregroundStyle(Theme.primary)
                            }
                            .font(.system(size: 10))
                            .lineLimit(4)
                            .textSelection(.enabled)
                        }
                    }
                    if !revision.gitCommit.isEmpty {
                        Text("commit \(revision.gitCommit)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .padding(.leading, 12)
                .padding(.vertical, 2)
            }
        }
    }
}
