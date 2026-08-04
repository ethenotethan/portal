import SwiftUI
import os.log

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "WikiEventsPage")

// MARK: - WikiEventsPageView

/// The wiki events page — a full page WITHIN the wiki, not an overlay.
/// The adaptive host (WikiGraphView) swaps the graph surface for this view
/// when `viewModel.showEventsPage` is on; "← Wiki" returns to the graph.
///
/// Three panes:
/// - the event plot (dots by kind on an event-time axis),
/// - the Event Feed — the same events as a chronological list,
///   selection-synced with the plot (tap a dot → the feed scrolls to
///   and highlights the row; tap a row → the dot lights up), every row with
///   a non-empty URL opening its source, and
/// - the expanded "knowledge accrued" pane (stat tiles, accrued curve,
///   input→output chart, pages touched from `/wiki/changes`).
///
/// Layout: macOS splits charts (left) from the feed (right); iOS stacks the
/// chart as a header over the scrolling feed.
///
/// Serves both backends off `WikiEventLogSource` (the plot + feed). The
/// "knowledge accrued" pane needs wiki-api's revisions/changes endpoints, which
/// Hermes has no counterpart for, so it renders only when the same source also
/// conforms to `WikiEventTimelineProviding` — present for Centaur, absent for
/// Hermes. Two capabilities rather than one is what lets the shared parts stay
/// shared instead of being forked per backend.
struct WikiEventsPageView: View {
    /// The event log — every backend that reaches this surface has one.
    internal let source: any WikiEventLogSource
    /// Shared wiki selection plane: page chips/rows navigate through it and
    /// return the surface to the graph/reader (openPageLeavingEvents).
    @ObservedObject var viewModel: WikiGraphViewModel

    @State private var windowDays: Int = 30
    @State private var eventTimeline: WikiEventTimeline?
    @State private var revisionsTimeline: WikiRevisionsTimeline?
    @State private var changesSummary: WikiChangesSummary?
    /// Selection plane shared by the dot plot and the feed (event id ==
    /// source_key). Either surface writes it; both react.
    @State private var selectedEventID: String?
    @State private var isLoading = false
    @State private var loadError: String?
    /// Source key of a focused event the log never yielded, kept so the page can
    /// say "that event isn't here" instead of looking like the click did nothing.
    @State private var focusNotFound: String?

    /// Also the ladder the view climbs when a focused event isn't in the
    /// current window. The last rung is the ceiling: beyond a year the honest
    /// answer is "not in the log" rather than an ever-growing fetch.
    private static let windowChoices = [7, 30, 90, 365]

    private static func windowLabel(_ days: Int) -> String {
        days >= 365 ? "1y" : "\(days)d"
    }

    /// The wiki-api-only enrichment provider, when this source has one.
    private var knowledgeProvider: (any WikiEventTimelineProviding)? {
        source as? (any WikiEventTimelineProviding)
    }

    /// Kind colors/labels/lanes from the wiki's own `type: event-type` pages.
    /// Empty for Centaur, whose kinds come from its pipeline and keep the
    /// built-in palette.
    private var presentation: WikiEventPresentation {
        WikiEventPresentation(registry: viewModel.eventTypes)
    }

    #if os(macOS)
    private let feedWidth: CGFloat = 360
    #endif

    /// The plotted x-domain. Prefer the server-resolved window; fall back to
    /// the picker while loading.
    private var window: ClosedRange<Date> {
        let until = eventTimeline?.until ?? Date()
        let since = eventTimeline?.since
            ?? Calendar.current.date(byAdding: .day, value: -windowDays, to: until)
            ?? until.addingTimeInterval(-86_400)
        return min(since, until)...max(since, until.addingTimeInterval(1))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let focusNotFound {
                focusMissingBanner(focusNotFound)
                Divider()
            }
            content
        }
        .background(Theme.background)
        .task(id: windowDays) { await load() }
        // A second provenance chip while already on the page: the key changes
        // but `windowDays` may not, so the window task alone wouldn't notice.
        .onChange(of: viewModel.focusedEventKey) { _, key in
            guard key != nil else { return }
            resolveFocusedEvent()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // Back to the graph — the events page is a wiki page, so leaving
            // it is navigation, not dismissal.
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    viewModel.showEventsPage = false
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Wiki")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.borderless)
            .help("Back to the wiki graph")

            Divider().frame(height: 14)

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Events")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            if let count = eventTimeline?.eventCount {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
            }

            Spacer()

            Picker("Window", selection: $windowDays) {
                ForEach(Self.windowChoices, id: \.self) { days in
                    Text(Self.windowLabel(days)).tag(days)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .labelsHidden()

            Button {
                Task { await load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    /// A changeset cited an event the log doesn't contain even at the widest
    /// window — a real fact about the wiki (the raw source was pruned, or the
    /// key is stale), and one worth naming rather than swallowing.
    private func focusMissingBanner(_ key: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
            Text("No event named ")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            + Text(key)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.primary)
            + Text(" in the log — the source may have been pruned.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 6)
            Button {
                focusNotFound = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.warning.opacity(0.08))
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading && eventTimeline == nil {
            Spacer()
            PortalProgressView(label: "Loading events…")
            Spacer()
        } else if let loadError, eventTimeline == nil {
            errorState(loadError)
        } else if let timeline = eventTimeline {
            if timeline.events.isEmpty && (revisionsTimeline?.buckets.isEmpty ?? true) {
                emptyState
            } else {
                adaptiveBody(timeline)
            }
        }
    }

    // MARK: Adaptive layout

    #if os(macOS)
    /// macOS: charts + knowledge pane (left, scrolling) | Event Feed (right).
    private func adaptiveBody(_ timeline: WikiEventTimeline) -> some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    plotSection(timeline)
                    Divider().padding(.vertical, 2)
                    knowledgeSection
                }
                .padding(14)
            }
            .frame(maxWidth: .infinity)

            Divider()

            WikiEventFeedView(
                events: timeline.events,
                selectedEventID: $selectedEventID,
                onOpenPage: { viewModel.openPageLeavingEvents($0) },
                presentation: presentation,
                onOpenChangeset: openChangeset
            )
            .frame(width: feedWidth)
        }
    }
    #else
    /// iOS: one scroll — plot as the header, feed beneath, knowledge last.
    private func adaptiveBody(_ timeline: WikiEventTimeline) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    plotSection(timeline)
                    Divider().padding(.vertical, 2)
                    WikiEventFeedList(
                        events: timeline.events,
                        selectedEventID: $selectedEventID,
                        onOpenPage: { viewModel.openPageLeavingEvents($0) },
                        presentation: presentation,
                        onOpenChangeset: openChangeset
                    )
                    Divider().padding(.vertical, 2)
                    knowledgeSection
                }
                .padding(14)
            }
            .onChange(of: selectedEventID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
    #endif

    private func plotSection(_ timeline: WikiEventTimeline) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            WikiEventsSectionLabel(
                "Ingestion events",
                detail: "what flowed into the knowledge base"
            )
            WikiEventKindLegend(
                eventsByKind: timeline.eventsByKind,
                presentation: presentation,
                onOpenKindPage: { viewModel.openPageLeavingEvents($0) }
            )
            WikiEventDotChart(
                events: timeline.events,
                window: window,
                selectedEventID: $selectedEventID,
                presentation: presentation
            )
            if timeline.events.contains(where: \.eventTimeEstimated) {
                Label("Diamond marks: event time estimated (only ingest time known)", systemImage: "questionmark.diamond")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
            unplottedNote(timeline)
        }
    }

    /// Why the plot is emptier than the feed, when it is.
    ///
    /// The feed lists an event whatever its timestamp; the plot can only draw
    /// one that has a time inside the window. Without this line the difference
    /// reads as a broken chart, which is the wrong conclusion and the wrong fix
    /// — the honest answer is a property of the wiki's data.
    @ViewBuilder
    private func unplottedNote(_ timeline: WikiEventTimeline) -> some View {
        let undated = timeline.undatedCount
        let outside = timeline.outOfWindowCount(domain: window)
        if undated > 0 || outside > 0 {
            Label(
                Self.unplottedSummary(undated: undated, outside: outside),
                systemImage: "eye.slash"
            )
            .font(.caption2)
            .foregroundStyle(Theme.tertiary)
        }
    }

    /// The note's text. Pure and internal so a test can pin the wording — an
    /// off-by-one or a mislabeled cause here misdirects whoever reads it.
    internal static func unplottedSummary(undated: Int, outside: Int) -> String {
        var clauses: [String] = []
        if undated > 0 {
            clauses.append("\(undated) with no timestamp")
        }
        if outside > 0 {
            clauses.append("\(outside) dated outside this window")
        }
        let total = undated + outside
        let noun = total == 1 ? "event" : "events"
        return "\(total) \(noun) not plotted: " + clauses.joined(separator: ", ")
    }

    /// Centaur-only: needs the revisions/changes endpoints. Rendering an empty
    /// shell on Hermes would read as "no knowledge accrued" rather than "this
    /// backend doesn't report it".
    @ViewBuilder
    private var knowledgeSection: some View {
        if knowledgeProvider != nil {
            WikiEventsKnowledgePane(
                eventTimeline: eventTimeline,
                revisionsTimeline: revisionsTimeline,
                changesSummary: changesSummary,
                window: window,
                onOpenPage: { viewModel.openPageLeavingEvents($0) }
            )
        }
    }

    /// Open the change this event caused. Leaves the events page for the graph
    /// surface, selects the page, and opens the changeset drawer scoped to it —
    /// the drawer filters by `selectedPagePath`, so landing on the page IS
    /// landing on its changeset history.
    private func openChangeset(_ ref: WikiEventChangesetRef) {
        guard !ref.page.isEmpty else { return }
        viewModel.openPageLeavingEvents(ref.page)
        viewModel.showTimeline = true
    }

    // MARK: Empty / error states

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiary)
            Text("No events in this window")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
            Text("Try a wider window.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundStyle(Theme.warning)
            Text("Couldn’t load the event timeline")
                .font(.callout)
                .foregroundStyle(Theme.primary)
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") { Task { await load() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            // Sequential awaits: the source is MainActor-isolated (an
            // async-let child task can't capture the non-Sendable
            // existential) and each call is one short round-trip.
            eventTimeline = try await source.fetchEventLog(
                days: Double(windowDays), since: nil, until: nil,
                wiki: viewModel.selectedWikiPath
            )
            selectedEventID = nil
            resolveFocusedEvent()
        } catch {
            loadError = error.localizedDescription
            return
        }
        // The knowledge panes are wiki-api enrichment: absent on Hermes, and on
        // Centaur a failure (older deployment without an endpoint) hides the
        // pane rather than erroring a page whose spine already loaded. Logged
        // rather than swallowed — "the pane is missing" and "the pane's endpoint
        // is broken" look identical on screen otherwise.
        guard let knowledgeProvider else { return }
        do {
            revisionsTimeline = try await knowledgeProvider.fetchRevisionsTimeline(
                days: Double(windowDays), since: nil, until: nil
            )
        } catch {
            log.warning("revisions timeline unavailable: \(error.localizedDescription, privacy: .public)")
        }
        do {
            changesSummary = try await knowledgeProvider.fetchChangesSummary(
                days: Double(windowDays), since: nil, until: nil
            )
        } catch {
            log.warning("changes summary unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Land on the event a provenance chip asked for, widening the window until
    /// the event appears.
    ///
    /// Arriving from "this change was caused by that event" onto a feed that
    /// doesn't contain the event would read as the event not existing, when the
    /// real reason is a 30-day default and an older source. So climb the window
    /// ladder rather than silently showing nothing.
    ///
    /// The key is consumed either way — a focus request that couldn't be
    /// satisfied must not re-fire on the next window change and drag the user
    /// back off whatever window they then chose. `focusNotFound` says so on
    /// screen instead.
    ///
    /// Widening is driven by `windowDays` rather than by fetching here: the
    /// picker's `.task(id: windowDays)` reloads on every change, so a local
    /// fetch loop would either be thrown away by that reload or have its
    /// selection cleared by it. Bumping one rung and keeping the key makes the
    /// reload the next iteration — one fetch per rung, and the branch above
    /// terminates it as soon as the event is in frame.
    private func resolveFocusedEvent() {
        guard let key = viewModel.focusedEventKey else { return }

        if eventTimeline?.events.contains(where: { $0.id == key }) == true {
            viewModel.focusedEventKey = nil
            focusNotFound = nil
            selectedEventID = key
            return
        }

        if let wider = Self.windowChoices.first(where: { $0 > windowDays }) {
            windowDays = wider
            return
        }

        // Ladder exhausted. Clear the key so a request that can't be satisfied
        // doesn't re-fire on every later window change and drag the user off
        // whatever window they then chose.
        viewModel.focusedEventKey = nil
        focusNotFound = key
    }
}

// MARK: - Section label

/// Shared "title + why it matters" section header for the events page panes.
struct WikiEventsSectionLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }
}
