import SwiftUI

// MARK: - CronRevisionTimelineDrawer

/// The dataflow graph's change history, as a drawer beside the graph: one row per
/// change, expanding in place to the typed diff that produced it.
///
/// Inline expansion rather than a nested sheet, for the same reason
/// `WikiChangesetInlineDiff` does it that way — the list is the context, and
/// pushing a sheet over it hides the neighbours you're comparing against. What
/// this surface has that the wiki's cannot is the graph right next to it: opening
/// a row also lights the change up on the canvas.
///
/// **Two logs, one drawer.** When the gateway records a history
/// (`cron.changesets`) these rows are that record: real change times, an actor,
/// and the turn that caused it. When it doesn't, they're Portal's own
/// observations — what the 10-second poll noticed — and the drawer says so above
/// them rather than degrading to an empty list, which would read as "nothing has
/// ever changed here". Which log is showing is decided in one place (`rows(_:_:)`)
/// so the header, the rows, and the caveat can't disagree.
///
/// Every claim is hedged exactly as much as its source deserves: an observation
/// says it's an observation, an older revision is highlighted against *current*
/// positions with whatever no longer exists admitted in a footnote rather than
/// silently dropped, and a diff the gateway can't supply says that instead of
/// showing an empty box.
internal struct CronRevisionTimelineDrawer: View {
    @ObservedObject internal var viewModel: CronGraphViewModel

    /// Where recorded history comes from, or nil when there's no gateway to ask
    /// (previews, and the inline card before a connection exists). Nil is not
    /// "unsupported" — nothing has been asked, so the drawer shows observations
    /// without claiming anything about the backend.
    internal let source: (any CronChangesetSource)?
    internal let onClose: () -> Void

    @StateObject private var feed = CronChangesetFeed()

    @MainActor
    internal init(
        viewModel: CronGraphViewModel,
        source: (any CronChangesetSource)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.source = source
        self.onClose = onClose
    }

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

    // MARK: - Which log

    /// The rows to draw, and which log they came from.
    ///
    /// Recorded history wins whenever there is any, because it answers strictly
    /// more: the observed log can't say when a change was made, who made it, or
    /// why, and a change made and reverted between two polls exists only in the
    /// gateway's record. Nothing recorded → the observations, which are still a
    /// real answer to a narrower question.
    internal enum Rows: Equatable {
        case recorded([CronChangeset])
        case observed([CronGraphRevision])

        internal var isEmpty: Bool {
            switch self {
            case .recorded(let rows): return rows.isEmpty
            case .observed(let rows): return rows.isEmpty
            }
        }
    }

    internal static func rows(recorded: [CronChangeset], observed: [CronGraphRevision]) -> Rows {
        recorded.isEmpty ? .observed(observed) : .recorded(recorded)
    }

    private var rows: Rows {
        Self.rows(recorded: feed.changesets, observed: viewModel.revisions)
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            if rows.isEmpty {
                emptyState
            } else {
                rowList
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface.opacity(0.97))
        .task {
            // Asked when the drawer opens rather than on app launch: this is the
            // only surface that reads it, and a gateway without the method
            // shouldn't be probed on a timer for an answer that won't change.
            guard let source else { return }
            await feed.load(from: source)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(isShowingRecorded ? "Changes" : "Revisions")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                if feed.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 10, height: 10)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Close the change history")
            }
            // The caveat, verbatim from whichever log this is: a count of rows
            // reads as a changelog unless it says what it actually is.
            Text(summaryLine)
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            // "Capability absent → say so." The note is above the rows, not
            // buried under them, because it changes what every row below means.
            if let note = feed.fallbackNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.warning.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var isShowingRecorded: Bool {
        if case .recorded = rows { return true }
        return false
    }

    private var summaryLine: String {
        guard isShowingRecorded else { return viewModel.revisionLogSummary }
        let shown = feed.changesets.count
        let scope = feed.total > shown ? "\(shown) of \(feed.total)" : "\(shown)"
        return "\(scope) change\(feed.total == 1 ? "" : "s") recorded by the gateway — when each "
            + "was made, and by whom."
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

    @ViewBuilder
    private var rowList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                switch rows {
                case .recorded(let changesets):
                    ForEach(changesets) { changeset in
                        changesetRow(changeset)
                    }
                case .observed(let revisions):
                    ForEach(Array(revisions.enumerated()), id: \.element.id) { offset, revision in
                        revisionRow(revision, isCurrent: offset == 0)
                    }
                }
            }
            .padding(8)
        }
    }

    /// Shared chrome for a row, so a recorded change and an observed revision are
    /// the same object on screen — they differ in what they can claim, not in how
    /// you operate them.
    private func rowContainer<Content: View>(
        isOpen: Bool, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6, content: content)
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

    // MARK: - Observed revisions

    @ViewBuilder
    private func revisionRow(_ revision: CronGraphRevision, isCurrent: Bool) -> some View {
        let isOpen = viewModel.isReviewing(rowID: revision.id.uuidString)

        rowContainer(isOpen: isOpen) {
            Button {
                viewModel.toggleReview(of: revision)
            } label: {
                rowLabel(digest: revision.shortDigest, isOpen: isOpen,
                         badge: isCurrent ? "on screen" : nil,
                         trailing: Self.relativeFormatter.localizedString(
                            for: revision.observedAt, relativeTo: Date()))
            }
            .buttonStyle(.borderless)
            .help(Self.absoluteFormatter.string(from: revision.observedAt)
                  + " — when this app noticed, not necessarily when the change was made")

            if isOpen {
                observedDiffBody(isCurrent: isCurrent)
            }
        }
    }

    private func rowLabel(
        digest: String, isOpen: Bool, badge: String?, trailing: String
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.secondary.opacity(0.7))
                .frame(width: 8)
            // `.monospaced()` re-asserts against the app typeface's root
            // `.fontDesign`: a proportional hash reads as a word, not an address.
            Text(digest)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .monospaced()
                .foregroundStyle(isOpen ? Theme.accent : Theme.primary)
            if let badge {
                Text(badge)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.success)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.success.opacity(0.12), in: Capsule())
            }
            Spacer()
            Text(trailing)
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func observedDiffBody(isCurrent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let diff = viewModel.reviewedDiff {
                if diff.isEmpty {
                    // Shouldn't happen — a revision exists because the commitment
                    // moved — so if it does, say so plainly instead of rendering an
                    // empty box that looks like a loading state.
                    note("The commitment changed but nothing structural differs. "
                         + "That's a gap between the digest and this diff, not a no-op change.")
                } else {
                    statements(diff, isCurrent: isCurrent)
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

    // MARK: - Recorded changesets

    @ViewBuilder
    private func changesetRow(_ changeset: CronChangeset) -> some View {
        let isOpen = viewModel.isReviewing(rowID: changeset.id)

        rowContainer(isOpen: isOpen) {
            Button {
                toggleRecordedReview(changeset)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    rowLabel(digest: changeset.shortDigest, isOpen: isOpen,
                             badge: isOnScreen(changeset) ? "on screen" : nil,
                             trailing: recordedTime(changeset))
                    subject(changeset)
                }
            }
            .buttonStyle(.borderless)
            .help(recordedHelp(changeset))

            if isOpen {
                recordedDiffBody(changeset)
            }
        }
    }

    /// The line under the digest: what changed and who changed it. The actor chip
    /// is the thing the observed log structurally cannot show, so it earns space
    /// on the collapsed row rather than hiding behind the chevron.
    @ViewBuilder
    private func subject(_ changeset: CronChangeset) -> some View {
        HStack(spacing: 5) {
            if !changeset.action.isEmpty {
                Text(changeset.action)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint(changeset.polarity))
            }
            if !changeset.job.isEmpty {
                Text(changeset.job)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            chip(icon: changeset.actor.icon, text: changeset.actor.label,
                 tint: changeset.actor.isRecorded ? Theme.accent : Theme.tertiary)
        }
        .padding(.leading, 14)
    }

    @ViewBuilder
    private func recordedDiffBody(_ changeset: CronChangeset) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // The gateway's prose, clearly attributed and clearly not the diff:
            // it's what someone wrote about the change, and the statements below
            // are what the two graphs actually differ by.
            if !changeset.summary.isEmpty {
                Text("“\(changeset.summary)”")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            switch feed.diffState(for: changeset) {
            case nil, .loading:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 10, height: 10)
                    Text("Reading what changed…")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.tertiary)
                }
            case .ready(let recorded):
                if let diff = recorded.statements, !diff.isEmpty {
                    statements(diff, isCurrent: isOnScreen(changeset))
                } else if recorded.statements == nil {
                    note("The gateway didn't say what the configuration was before this change, "
                         + "so there's nothing to compare it against — the change is recorded, "
                         + "its contents aren't.")
                } else {
                    note("The gateway recorded this change but its two configurations are "
                         + "identical, so there's nothing structural to show.")
                }
                if let text = recorded.unifiedText {
                    unifiedDiff(text)
                }
            case .failed(let message):
                note("Couldn't read this change's diff (\(message)).")
                Button("Try again") { loadRecordedDiff(changeset) }
                    .font(.system(size: 9.5))
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
            }

            provenance(changeset)
        }
        .padding(.leading, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The "why", and the honest version of not having one.
    @ViewBuilder
    private func provenance(_ changeset: CronChangeset) -> some View {
        if changeset.provenance.isRecorded {
            HStack(spacing: 4) {
                Text("from")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                ForEach(changeset.provenance.turns) { turn in
                    chip(icon: "bubble.left.and.text.bubble.right", text: turn.shortLabel,
                         tint: Theme.accent)
                        .help(turn.key)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        } else {
            note("No session was recorded as the cause — which isn't the same as there not "
                 + "having been one.")
        }
        if !changeset.gitCommit.isEmpty {
            chip(icon: "arrow.triangle.branch", text: changeset.gitCommit, tint: Theme.secondary)
                .help("The commit the job definitions were at")
        }
    }

    /// The text diff, when job definitions are file-backed. Height-capped and
    /// scrollable: it's supporting evidence under the statements, and letting it
    /// run to full height would push the next row off screen.
    private func unifiedDiff(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        }
        .frame(maxHeight: 160)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        .padding(.top, 3)
    }

    // MARK: - Statements, shared by both logs

    /// Both logs render the same sentences from the same `CronGraphDiff` — the
    /// point of having `cron.changeset_diff` return graphs rather than prose.
    @ViewBuilder
    private func statements(_ diff: CronGraphDiff, isCurrent: Bool) -> some View {
        ForEach(diff.changes) { change in
            statementRow(change)
        }
        footnotes(diff, isCurrent: isCurrent)
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

    // MARK: - Review plumbing

    private func toggleRecordedReview(_ changeset: CronChangeset) {
        let wasOpen = viewModel.isReviewing(rowID: changeset.id)
        viewModel.toggleReview(rowID: changeset.id, diff: recordedStatements(changeset))
        guard !wasOpen else { return }
        loadRecordedDiff(changeset)
    }

    private func loadRecordedDiff(_ changeset: CronChangeset) {
        guard let source else { return }
        Task { @MainActor in
            await feed.loadDiff(for: changeset, from: source)
            // Re-read through the feed rather than trusting a captured value: the
            // fetch may have been skipped because another row's request already
            // resolved it. `updateReviewedDiff` drops the result if this row is
            // no longer the open one.
            viewModel.updateReviewedDiff(recordedStatements(changeset), forRow: changeset.id)
        }
    }

    private func recordedStatements(_ changeset: CronChangeset) -> CronGraphDiff? {
        guard case .ready(let recorded) = feed.diffState(for: changeset) else { return nil }
        return recorded.statements
    }

    // MARK: - Recorded row phrasing

    /// Whether a recorded change produced the wiring currently drawn.
    ///
    /// A digest match is proof; a mismatch proves nothing, because the gateway's
    /// commitment need not be computed over the same canonical form as
    /// `CronGraphDigest`. That asymmetry is why the badge is the only thing keyed
    /// on this — the "highlighted against the current wiring" footnote is true
    /// either way, so nothing is claimed from a mismatch.
    private func isOnScreen(_ changeset: CronChangeset) -> Bool {
        !changeset.digest.isEmpty && changeset.digest == viewModel.digest.hex
    }

    private func recordedTime(_ changeset: CronChangeset) -> String {
        guard let date = changeset.date else { return "time not recorded" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func recordedHelp(_ changeset: CronChangeset) -> String {
        guard let date = changeset.date else {
            return changeset.timestamp.isEmpty
                ? "The gateway recorded this change without a time"
                : "The gateway sent \"\(changeset.timestamp)\", which this app couldn't read as a date"
        }
        return Self.absoluteFormatter.string(from: date) + " — when the change was made"
    }

    // MARK: - Bits

    private func chip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 7.5, weight: .semibold))
            Text(text)
                .font(.system(size: 8.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.12), in: Capsule())
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
