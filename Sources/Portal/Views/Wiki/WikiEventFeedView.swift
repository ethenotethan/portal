import SwiftUI

// MARK: - WikiEventFeedView (macOS pane)

/// The Event Feed: the same `/wiki/timeline` events as a chronological list
/// (newest first), selection-synced with the dot plot through the shared
/// `selectedEventID`. Selecting a dot scrolls the feed to the row and
/// highlights it; tapping a row lights up the dot. Hosted as the right pane
/// on macOS; iOS embeds `WikiEventFeedList` in the page scroll instead.
struct WikiEventFeedView: View {
    let events: [WikiTimelineEvent]
    @Binding var selectedEventID: String?
    /// Directive target-page chips → shared selection plane.
    var onOpenPage: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                Text("Event Feed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                Text("\(events.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.surface)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    WikiEventFeedList(
                        events: events,
                        selectedEventID: $selectedEventID,
                        onOpenPage: onOpenPage
                    )
                    .padding(10)
                }
                .onChange(of: selectedEventID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.background)
    }
}

// MARK: - WikiEventFeedList

/// The feed rows themselves (no scroll container) so macOS wraps them in the
/// pane's ScrollView and iOS lays them into the page's single scroll. Rows
/// are `.id(event.id)` for ScrollViewReader targeting from either host.
struct WikiEventFeedList: View {
    let events: [WikiTimelineEvent]
    @Binding var selectedEventID: String?
    var onOpenPage: ((String) -> Void)?

    /// Newest first — a feed reads downward into the past. The server
    /// already orders DESC; re-sort defensively for stability.
    private var ordered: [WikiTimelineEvent] {
        events.sorted { ($0.eventDate ?? .distantPast) > ($1.eventDate ?? .distantPast) }
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if events.isEmpty {
                Text("No events in this window.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.vertical, 8)
            }
            ForEach(ordered) { event in
                WikiEventFeedRow(
                    event: event,
                    isSelected: selectedEventID == event.id,
                    onSelect: {
                        selectedEventID = selectedEventID == event.id ? nil : event.id
                    },
                    onOpenPage: onOpenPage
                )
                .id(event.id)
            }
        }
    }
}

// MARK: - WikiEventFeedRow

/// One feed entry: kind dot + chip, label (directive rows show the actor +
/// verbatim quote), relative timestamp, an open-source affordance when the
/// event has a URL, and directive target-page chips that jump into the wiki.
struct WikiEventFeedRow: View {
    let event: WikiTimelineEvent
    let isSelected: Bool
    let onSelect: () -> Void
    var onOpenPage: ((String) -> Void)?

    @Environment(\.openURL) private var openURL

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var sourceURL: URL? {
        event.url.isEmpty ? nil : URL(string: event.url)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Circle()
                    .fill(WikiEventKindStyle.color(for: event.kind))
                    .frame(width: 7, height: 7)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3 }

                Text(event.kind == .other ? event.kindRaw : event.kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.secondary)

                Spacer(minLength: 4)

                if let date = event.eventDate {
                    Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.tertiary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }

                if let url = sourceURL {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.borderless)
                    .help("Open source: \(event.url)")
                }
            }

            if event.isDirective {
                directiveLabel
            } else {
                Text(event.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let pages = event.targetPages, !pages.isEmpty {
                FlowLayout(spacing: 5) {
                    ForEach(pages, id: \.self) { page in
                        Button {
                            onOpenPage?(page)
                        } label: {
                            Text(WikiEventFeedRow.shortPageName(page))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.surfaceHover, in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.borderless)
                        .help("Open \(page) in the wiki")
                    }
                }
            }

            if isSelected {
                selectedDetail
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Theme.surfaceHover : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Theme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { onSelect() }
    }

    /// Expanded detail on the selected row: exact timestamps (event vs
    /// ingest, flagging estimated event time) and directive status/revision
    /// enrichment — what the old popover card carried, inline in the feed.
    @ViewBuilder
    private var selectedDetail: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let occurred = event.occurredAt {
                detailRow(
                    icon: "clock",
                    title: event.eventTimeEstimated ? "Event time (estimated)" : "Event time",
                    value: occurred.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if let ingested = event.ingestedAt {
                detailRow(
                    icon: "tray.and.arrow.down",
                    title: "Ingested",
                    value: ingested.formatted(date: .abbreviated, time: .shortened)
                )
            }
            if event.eventTimeEstimated {
                Label("Only ingest time is known for this event", systemImage: "questionmark.diamond")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
            }
            if let status = event.directiveStatus, !status.isEmpty {
                detailRow(icon: "bolt.fill", title: "Status", value: status)
            }
            if let revisions = event.resultingRevisionIDs, !revisions.isEmpty {
                detailRow(
                    icon: "square.and.pencil",
                    title: "Revisions",
                    value: revisions.map(String.init).joined(separator: ", ")
                )
            }
        }
        .padding(.top, 2)
    }

    private func detailRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Theme.tertiary)
            Text(title)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
            Spacer(minLength: 6)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }

    /// "Greg: “always list the glossary pages first”" — actor + quote is the
    /// row's identity for directives.
    private var directiveLabel: some View {
        (Text(event.actorName ?? event.actorSlackID ?? "unknown")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.primary)
        + Text(": “\(event.directiveExcerpt ?? event.label)”")
            .font(.system(size: 12))
            .foregroundColor(Theme.primary))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "wiki:topic:glossary-mcp" → "glossary-mcp" for chip labels.
    static func shortPageName(_ docID: String) -> String {
        docID.split(separator: ":").last.map(String.init) ?? docID
    }
}
