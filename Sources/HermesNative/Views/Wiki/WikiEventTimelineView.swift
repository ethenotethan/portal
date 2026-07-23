import SwiftUI

// MARK: - WikiEventTimelineView

/// The Compendium ingestion timeline for Centaur wikis: every raw event that
/// flowed into the LLM-synthesized knowledge base plotted on an event-time
/// axis (dots by kind), with the page-revision volume — the knowledge that
/// accrued from those inputs — charted underneath. Data comes from wiki-api
/// `/wiki/timeline` + `/wiki/revisions-timeline` via
/// `WikiEventTimelineProviding` (Centaur-only by conformance).
struct WikiEventTimelineView: View {
    let provider: any WikiEventTimelineProviding
    /// Shared wiki selection plane: directive target-page chips navigate
    /// through it so "jump into the wiki" lands in the same reader/graph.
    @ObservedObject var viewModel: WikiGraphViewModel
    var onClose: (() -> Void)?

    @State private var windowDays: Int = 30
    @State private var eventTimeline: WikiEventTimeline?
    @State private var revisionsTimeline: WikiRevisionsTimeline?
    @State private var selectedEvent: WikiTimelineEvent?
    @State private var showCumulative = true
    @State private var isLoading = false
    @State private var loadError: String?

    private static let windowChoices = [7, 30, 90]

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

            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close")
            }
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
            HermesProgressView(label: "Loading events…")
            Spacer()
        } else if let loadError, eventTimeline == nil {
            errorState(loadError)
        } else if let timeline = eventTimeline {
            if timeline.events.isEmpty && (revisionsTimeline?.buckets.isEmpty ?? true) {
                emptyState
            } else {
                charts(timeline)
            }
        }
    }

    private func charts(_ timeline: WikiEventTimeline) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionLabel(
                    "Ingestion events",
                    detail: "what flowed into the knowledge base"
                )
                WikiEventKindLegend(eventsByKind: timeline.eventsByKind)
                WikiEventDotChart(
                    events: timeline.events,
                    window: window,
                    selectedEvent: $selectedEvent
                ) { event in
                    WikiEventDetailCard(event: event, onOpenPage: openPage)
                }

                if timeline.events.contains(where: \.eventTimeEstimated) {
                    Label("Diamond marks: event time estimated (only ingest time known)", systemImage: "questionmark.diamond")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }

                Divider().padding(.vertical, 2)

                HStack {
                    sectionLabel(
                        "Knowledge accrued",
                        detail: revisionsSubtitle
                    )
                    Spacer()
                    Picker("Measure", selection: $showCumulative) {
                        Text("Cumulative").tag(true)
                        Text("Per \(revisionsTimeline?.unit ?? "day")").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                }

                if let revisions = revisionsTimeline {
                    WikiRevisionsChart(
                        timeline: revisions,
                        window: window,
                        showCumulative: showCumulative
                    )
                } else {
                    Text("No revision data for this window.")
                        .font(.caption)
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(14)
        }
    }

    private var revisionsSubtitle: String {
        guard let revisions = revisionsTimeline else { return "page edits over time" }
        return "\(revisions.totalInWindow) page edits in window · \(revisions.baseline) before"
    }

    private func sectionLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }

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

    // MARK: Actions

    /// Directive target-page chip → shared selection plane: the page becomes
    /// the current wiki page and the reader presents it (same path as the
    /// changesets timeline rows).
    private func openPage(_ path: String) {
        selectedEvent = nil
        onClose?()
        viewModel.navigate(to: path)
        viewModel.openReaderForSelection()
    }

    private func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            // Sequential awaits: the provider is MainActor-isolated (an
            // async-let child task can't capture the non-Sendable
            // existential) and both calls are short GETs.
            eventTimeline = try await provider.fetchEventTimeline(
                days: Double(windowDays), since: nil, until: nil
            )
            revisionsTimeline = try await provider.fetchRevisionsTimeline(
                days: Double(windowDays), since: nil, until: nil
            )
            selectedEvent = nil
        } catch {
            loadError = error.localizedDescription
        }
    }
}

// MARK: - WikiEventDetailCard

/// Popover detail for a tapped event dot: label, kind, timestamps (flagging
/// estimated times), an open-link affordance when a URL exists, and for
/// directives the actor + verbatim quote + target-page chips that jump into
/// the wiki + resulting-revision ids.
struct WikiEventDetailCard: View {
    let event: WikiTimelineEvent
    var onOpenPage: ((String) -> Void)?

    @Environment(\.openURL) private var openURL

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(WikiEventKindStyle.color(for: event.kind))
                    .frame(width: 8, height: 8)
                Text(event.kind == .other ? event.kindRaw : event.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if !event.url.isEmpty, let url = URL(string: event.url) {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open link", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.accent)
                }
            }

            if event.isDirective {
                directiveSection
            } else {
                Text(event.label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            timestampRows
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 340, alignment: .leading)
    }

    // MARK: Directive enrichment

    @ViewBuilder
    private var directiveSection: some View {
        // "directive from <actor>: "<quote>""
        (Text("directive from ")
            .font(.system(size: 13))
            .foregroundColor(Theme.secondary)
        + Text(event.actorName ?? event.actorSlackID ?? "unknown")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Theme.primary)
        + Text(": “\(event.directiveExcerpt ?? event.label)”")
            .font(.system(size: 13))
            .foregroundColor(Theme.primary))
            .fixedSize(horizontal: false, vertical: true)

        if let status = event.directiveStatus, !status.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8))
                Text(status)
                    .font(.caption2)
            }
            .foregroundStyle(Theme.tertiary)
        }

        if let pages = event.targetPages, !pages.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(pages, id: \.self) { page in
                    Button {
                        onOpenPage?(page)
                    } label: {
                        Text(shortPageName(page))
                            .font(.caption2)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.surfaceHover, in: Capsule())
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.borderless)
                    .help("Open \(page) in the wiki")
                }
            }
        }

        if let revisions = event.resultingRevisionIDs, !revisions.isEmpty {
            Text("revisions: \(revisions.map(String.init).joined(separator: ", "))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    /// "wiki:topic:glossary-mcp" → "glossary-mcp" for chip labels.
    private func shortPageName(_ docID: String) -> String {
        docID.split(separator: ":").last.map(String.init) ?? docID
    }

    // MARK: Timestamps

    @ViewBuilder
    private var timestampRows: some View {
        if let occurred = event.occurredAt {
            timestampRow(
                icon: "clock",
                title: event.eventTimeEstimated ? "Event time (estimated)" : "Event time",
                date: occurred
            )
        }
        if let ingested = event.ingestedAt {
            timestampRow(icon: "tray.and.arrow.down", title: "Ingested", date: ingested)
        }
        if event.eventTimeEstimated {
            Label("Only ingest time is known for this event", systemImage: "questionmark.diamond")
                .font(.caption2)
                .foregroundStyle(Theme.warning)
        }
    }

    private func timestampRow(icon: String, title: String, date: Date) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
            Spacer()
            Text(Self.timestampFormatter.string(from: date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }
}
