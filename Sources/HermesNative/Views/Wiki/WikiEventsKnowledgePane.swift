import SwiftUI
import Charts

// MARK: - WikiEventsKnowledgePane

/// The expanded "Knowledge accrued" pane of the Compendium events page:
/// - stat tiles (all-time revisions, revisions this window, busiest bucket,
///   pages touched),
/// - the cumulative accrued curve / per-bucket bars (measure toggle), and
/// - the input→output story the two endpoints were designed to tell: input
///   events stacked by kind per bucket over output revisions per bucket, as
///   two x-aligned charts (never dual-axed), plus
/// - the pages touched in the window (from `/wiki/changes`), each row
///   jumping into the wiki through the shared selection plane.
struct WikiEventsKnowledgePane: View {
    let eventTimeline: WikiEventTimeline?
    let revisionsTimeline: WikiRevisionsTimeline?
    /// nil when the source doesn't serve /wiki/changes — the pages-touched
    /// tile and list simply hide.
    let changesSummary: WikiChangesSummary?
    let window: ClosedRange<Date>
    var onOpenPage: ((String) -> Void)?

    @State private var showCumulative = true
    @State private var showAllPages = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                WikiEventsSectionLabel(
                    "Knowledge accrued",
                    detail: subtitle
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

            statTiles

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

            if let events = eventTimeline, let revisions = revisionsTimeline,
               !events.events.isEmpty, !revisions.buckets.isEmpty {
                Divider().padding(.vertical, 2)
                WikiEventsInputOutputChart(
                    events: events.events,
                    revisions: revisions,
                    window: window
                )
            }

            if let changes = changesSummary, !changes.pages.isEmpty {
                Divider().padding(.vertical, 2)
                pagesTouched(changes)
            }
        }
    }

    private var subtitle: String {
        guard let revisions = revisionsTimeline else { return "page edits over time" }
        return "\(revisions.totalInWindow) page edits in window · \(revisions.baseline) before"
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        let columns = [GridItem(.adaptive(minimum: 130, maximum: 220), spacing: 8, alignment: .topLeading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            WikiEventsStatTile(
                label: "Total revisions",
                value: (revisionsTimeline?.totalAllTime).map(format) ?? "—",
                detail: "all time"
            )
            WikiEventsStatTile(
                label: "This window",
                value: (revisionsTimeline?.totalInWindow).map(format) ?? "—",
                detail: "\(eventTimeline?.eventCount ?? 0) input events"
            )
            WikiEventsStatTile(
                label: busiestLabel,
                value: (revisionsTimeline?.busiestBucket?.count).map(format) ?? "—",
                detail: busiestDetail
            )
            if let changes = changesSummary {
                WikiEventsStatTile(
                    label: "Pages touched",
                    value: format(changes.pageCount),
                    detail: pagesByTypeDetail(changes)
                )
            }
        }
    }

    private var busiestLabel: String {
        "Busiest \(revisionsTimeline?.unit ?? "day")"
    }

    private var busiestDetail: String {
        guard let bucket = revisionsTimeline?.busiestBucket?.bucket else { return "no edits" }
        return bucket.formatted(date: .abbreviated, time: revisionsTimeline?.unit == "hour" ? .shortened : .omitted)
    }

    private func pagesByTypeDetail(_ changes: WikiChangesSummary) -> String {
        let parts = changes.pagesByType
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map { "\($0.value) \($0.key)" }
        return parts.isEmpty ? "in window" : parts.joined(separator: " · ")
    }

    private func format(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    // MARK: Pages touched

    private func pagesTouched(_ changes: WikiChangesSummary) -> some View {
        let visible = showAllPages ? changes.pages : Array(changes.pages.prefix(8))
        return VStack(alignment: .leading, spacing: 8) {
            WikiEventsSectionLabel(
                "Pages touched",
                detail: "wiki pages created or updated in this window"
            )
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visible) { page in
                    WikiChangedPageRow(page: page, onOpenPage: onOpenPage)
                }
            }
            if changes.pages.count > 8 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showAllPages.toggle() }
                } label: {
                    Text(showAllPages ? "Show fewer" : "Show all \(changes.pages.count)")
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}

// MARK: - Stat tile

/// Events-page stat tile: label in a text token, compact semibold value,
/// muted detail line. Values never wear a series color (dataviz contract).
struct WikiEventsStatTile: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}

// MARK: - Changed page row

/// One row of the pages-touched list: type-colored dot, title (a button into
/// the wiki via the shared selection plane), type chip, relative timestamp,
/// and an external-link affordance when the page has a canonical URL.
struct WikiChangedPageRow: View {
    let page: WikiChangesSummary.PageChange
    var onOpenPage: ((String) -> Void)?

    @Environment(\.openURL) private var openURL

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onOpenPage?(page.id)
            } label: {
                HStack(spacing: 6) {
                    Text(page.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.primary)
                        .lineLimit(1)
                    Text(page.type)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Theme.surfaceHover, in: Capsule())
                        .foregroundStyle(Theme.secondary)
                }
            }
            .buttonStyle(.borderless)
            .help("Open \(page.id) in the wiki")

            Spacer(minLength: 4)

            if let updated = page.updatedAt {
                Text(Self.relativeFormatter.localizedString(for: updated, relativeTo: Date()))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }

            if !page.url.isEmpty, let url = URL(string: page.url) {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.borderless)
                .help("Open source: \(page.url)")
            }
        }
        .padding(.vertical, 3)
    }
}
