import SwiftUI

// MARK: - WikiEventsPageView

/// The Compendium events page — a full page WITHIN the wiki, not an overlay.
/// The adaptive host (WikiGraphView) swaps the graph surface for this view
/// when `viewModel.showEventsPage` is on; "← Wiki" returns to the graph.
///
/// Three panes, mirroring the Darkbloom docs SPA:
/// - the event plot (dots by kind on an event-time axis),
/// - the Event Feed — the same `/wiki/timeline` events as a chronological
///   list, selection-synced with the plot (tap a dot → the feed scrolls to
///   and highlights the row; tap a row → the dot lights up), every row with
///   a non-empty URL opening its source, and
/// - the expanded "knowledge accrued" pane (stat tiles, accrued curve,
///   input→output chart, pages touched from `/wiki/changes`).
///
/// Layout: macOS splits charts (left) from the feed (right); iOS stacks the
/// chart as a header over the scrolling feed. Data comes from wiki-api via
/// `WikiEventTimelineProviding` (Centaur-only by conformance).
struct WikiEventsPageView: View {
    let provider: any WikiEventTimelineProviding
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

    private static let windowChoices = [7, 30, 90]

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
            content
        }
        .background(Theme.background)
        .task(id: windowDays) { await load() }
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
            Text("Compendium Events")
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
                    Text("\(days)d").tag(days)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
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
                onOpenPage: { viewModel.openPageLeavingEvents($0) }
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
                        onOpenPage: { viewModel.openPageLeavingEvents($0) }
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
            WikiEventKindLegend(eventsByKind: timeline.eventsByKind)
            WikiEventDotChart(
                events: timeline.events,
                window: window,
                selectedEventID: $selectedEventID
            )
            if timeline.events.contains(where: \.eventTimeEstimated) {
                Label("Diamond marks: event time estimated (only ingest time known)", systemImage: "questionmark.diamond")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var knowledgeSection: some View {
        WikiEventsKnowledgePane(
            eventTimeline: eventTimeline,
            revisionsTimeline: revisionsTimeline,
            changesSummary: changesSummary,
            window: window,
            onOpenPage: { viewModel.openPageLeavingEvents($0) }
        )
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
            // Sequential awaits: the provider is MainActor-isolated (an
            // async-let child task can't capture the non-Sendable
            // existential) and all three calls are short GETs.
            eventTimeline = try await provider.fetchEventTimeline(
                days: Double(windowDays), since: nil, until: nil
            )
            revisionsTimeline = try await provider.fetchRevisionsTimeline(
                days: Double(windowDays), since: nil, until: nil
            )
            selectedEventID = nil
        } catch {
            loadError = error.localizedDescription
            return
        }
        // Pages-touched summary is enrichment, not the page's spine — a
        // failure (older wiki-api without /wiki/changes) degrades to hiding
        // that pane rather than erroring the whole page.
        changesSummary = try? await provider.fetchChangesSummary(
            days: Double(windowDays), since: nil, until: nil
        )
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
