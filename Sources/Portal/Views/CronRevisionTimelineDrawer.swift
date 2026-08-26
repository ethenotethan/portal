import SwiftUI

// MARK: - CronRevisionTimelineDrawer

/// The dataflow graph's revision history, as a drawer beside the graph: one row
/// per observed commitment, expanding in place to the typed diff that produced it.
///
/// Inline expansion rather than a nested sheet, for the same reason
/// `WikiChangesetInlineDiff` does it that way — the list is the context, and
/// pushing a sheet over it hides the neighbours you're comparing against. What
/// this surface has that the wiki's cannot is the graph right next to it: opening
/// a row also lights the change up on the canvas.
///
/// Every claim here is hedged exactly as much as the log deserves. These are
/// observations, not authorship (`CronGraphRevisionStore`), the newest one is the
/// wiring on screen, and an older one is highlighted against *current* positions
/// with whatever no longer exists admitted in a footnote rather than silently
/// dropped.
internal struct CronRevisionTimelineDrawer: View {
    @ObservedObject internal var viewModel: CronGraphViewModel
    internal let onClose: () -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let absoluteFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if viewModel.revisions.isEmpty {
                emptyState
            } else {
                revisionList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface.opacity(0.97))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Revisions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close the revision history")
            }
            // The caveat, verbatim from the store: a count of revisions reads as a
            // changelog unless it says what it actually is.
            Text(viewModel.revisionLogSummary)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 22))
                .foregroundStyle(Theme.secondary.opacity(0.5))
            Text("Nothing observed yet")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
            Text("The log starts the first time this app reads the graph, and gains an entry whenever the wiring changes.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Rows

    private var revisionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(Array(viewModel.revisions.enumerated()), id: \.element.id) { offset, revision in
                    revisionRow(revision, isCurrent: offset == 0)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func revisionRow(_ revision: CronGraphRevision, isCurrent: Bool) -> some View {
        let isOpen = viewModel.reviewedRevisionID == revision.id

        VStack(alignment: .leading, spacing: 6) {
            Button {
                viewModel.toggleReview(of: revision)
            } label: {
                rowLabel(revision, isCurrent: isCurrent, isOpen: isOpen)
            }
            .buttonStyle(.borderless)
            .help(Self.absoluteFormatter.string(from: revision.observedAt)
                  + " — when this app noticed, not necessarily when the change was made")

            if isOpen {
                diffBody(revision, isCurrent: isCurrent)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isOpen ? Theme.accent.opacity(0.07) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isOpen ? Theme.accent.opacity(0.35) : Theme.border.opacity(0.5), lineWidth: 1)
        )
    }

    private func rowLabel(_ revision: CronGraphRevision, isCurrent: Bool, isOpen: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.secondary.opacity(0.7))
                .frame(width: 8)
            // `.monospaced()` re-asserts against the app typeface's root
            // `.fontDesign`: a proportional hash reads as a word, not an address.
            Text(revision.shortDigest)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .monospaced()
                .foregroundStyle(isOpen ? Theme.accent : Theme.primary)
            if isCurrent {
                Text("on screen")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.success.opacity(0.12), in: Capsule())
            }
            Spacer()
            Text(Self.relativeFormatter.localizedString(for: revision.observedAt, relativeTo: Date()))
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
        }
        .contentShape(Rectangle())
    }

    // MARK: - The diff, inline

    @ViewBuilder
    private func diffBody(_ revision: CronGraphRevision, isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let diff = viewModel.reviewedDiff {
                if diff.isEmpty {
                    // Shouldn't happen — a revision exists because the commitment
                    // moved — so if it does, say so plainly instead of rendering an
                    // empty box that looks like a loading state.
                    note("The commitment changed but nothing structural differs. "
                         + "That's a gap between the digest and this diff, not a no-op change.")
                } else {
                    ForEach(diff.changes) { change in
                        statementRow(change)
                    }
                    footnotes(diff, isCurrent: isCurrent)
                }
            } else {
                note("The revision before this one is no longer on record, so there's nothing "
                     + "to compare it against. The log keeps the most recent entries and drops "
                     + "its tail.")
            }
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statementRow(_ change: CronGraphChange) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol(change.polarity))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint(change.polarity))
                .padding(.top, 1.5)
            Text(change.summary)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    /// What the graph beside this row can and can't show. Both of these are the
    /// difference between a highlight you can trust and one that quietly implies
    /// it covered everything.
    @ViewBuilder
    private func footnotes(_ diff: CronGraphDiff, isCurrent: Bool) -> some View {
        if !isCurrent {
            note("Highlighted on the graph against the current wiring — this revision isn't "
                 + "the one on screen.")
        }
        let unreachable = viewModel.reviewedChangesNotOnScreen
        if unreachable > 0 {
            note("\(unreachable) of \(diff.count) "
                 + (unreachable == 1 ? "change names a node" : "changes name nodes")
                 + " that isn't in the graph any more, so "
                 + (unreachable == 1 ? "it can't" : "they can't") + " be highlighted.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(Theme.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
    }

    private func symbol(_ polarity: CronGraphChange.Polarity) -> String {
        switch polarity {
        case .added:    return "plus"
        case .removed:  return "minus"
        case .modified: return "pencil"
        }
    }

    private func tint(_ polarity: CronGraphChange.Polarity) -> Color {
        switch polarity {
        case .added:    return Theme.success
        case .removed:  return Theme.warning
        case .modified: return Theme.accent
        }
    }
}
