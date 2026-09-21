import Foundation

// MARK: - WikiEventKind

/// Ingestion-source kind for a Compendium timeline event. The wiki-api emits
/// free-form strings ("github_pr", "linear", …); unknown kinds fold into
/// `.other` so new upstream sources never break decoding.
enum WikiEventKind: String, CaseIterable, Hashable {
    case githubPR = "github_pr"
    case linear
    case slack
    case drive
    case directive
    case openrouterStats = "openrouter_stats"
    case other

    init(wire: String) {
        self = WikiEventKind(rawValue: wire) ?? .other
    }

    var displayName: String {
        switch self {
        case .githubPR: return "GitHub PR"
        case .linear: return "Linear"
        case .slack: return "Slack"
        case .drive: return "Drive"
        case .directive: return "Directive"
        case .openrouterStats: return "OpenRouter"
        case .other: return "Other"
        }
    }
}

// MARK: - WikiEventChangesetRef

/// A changeset this event caused — the event→page edge of provenance.
///
/// The reverse direction already exists: `WikiChangeset.provenance` lists the
/// event keys that caused a change. The harness's `wiki.events` reports the
/// join in both directions off one index read, so a surface can walk event →
/// changeset → page without a second round-trip. An event with no recorded
/// changesets carries an empty array and the affordance simply doesn't render.
internal struct WikiEventChangesetRef: Identifiable, Hashable {
    internal let id: String
    /// Wiki-relative page path — what the changeset edited.
    internal let page: String
    internal let title: String
    /// create | update | archive | delete, verbatim from the wire.
    internal let action: String
    internal let timestamp: Date?

    /// Page title when the changeset recorded one, else the path's last
    /// component — a chip needs a label either way.
    internal var pageLabel: String {
        if !title.isEmpty { return title }
        return page.split(separator: "/").last.map(String.init) ?? page
    }
}

// MARK: - WikiTimelineEvent

/// One raw INPUT event that flowed into a knowledge base — a raw source file
/// under `raw/`, as reported by the harness's `wiki.events`.
///
/// One row type for the plot and the feed. Fields a source doesn't carry stay
/// nil/empty rather than being faked — directive attribution is only present
/// for directive kinds — and every view that shows them checks first.
struct WikiTimelineEvent: Identifiable, Hashable {
    let sourceKey: String
    /// Wire kind string. The presentation layer resolves this through the
    /// wiki's `type: event-type` pages (`WikiEventTypeRegistry`) and only falls
    /// back to `WikiEventKind`'s built-in palette for kinds the wiki hasn't
    /// declared.
    let kindRaw: String
    let label: String
    /// May be empty — not every source has a canonical link.
    let url: String
    /// Real-world event time. nil when the pipeline only knows ingest time.
    let occurredAt: Date?
    /// Pipeline ingest time.
    let ingestedAt: Date?
    /// True when only ingest time is known (pre-column rows).
    let eventTimeEstimated: Bool

    // Directive-only enrichment (nil for other kinds).
    let actorSlackID: String?
    let actorName: String?
    let directiveBody: String?
    let directiveExcerpt: String?
    /// Wiki page document ids the directive targeted.
    let targetPages: [String]?
    let directiveStatus: String?
    let resultingRevisionIDs: [Int64]?

    /// Changesets this event caused. The event → changeset → page navigation
    /// edge.
    internal var changesets: [WikiEventChangesetRef] = []
    /// Content hash of the raw source.
    internal var sha256: String = ""

    var id: String { sourceKey }
    var kind: WikiEventKind { WikiEventKind(wire: kindRaw) }
    /// The plotted time: real-world event time, falling back to ingest time.
    var eventDate: Date? { occurredAt ?? ingestedAt }
    var isDirective: Bool { kind == .directive }
}

// MARK: - WikiEventTimeline

/// The ingestion event log over a window: every ingested source as an event on
/// a single event-time axis, plus per-kind counts for the legend.
struct WikiEventTimeline {
    let since: Date?
    let until: Date?
    let eventCount: Int
    /// Wire-kind string → count (e.g. "github_pr": 40).
    let eventsByKind: [String: Int]
    let events: [WikiTimelineEvent]

    /// Events the log returned with no usable time.
    ///
    /// These are real events — the feed lists them and the legend counts them —
    /// but a dot plot has no x for them, so the plot leaves them out. Worth
    /// counting so the page can say so: an event present in the feed and absent
    /// from the plot otherwise reads as the plot being broken.
    internal var undatedCount: Int {
        events.count { $0.eventDate == nil }
    }

    /// Dated events whose time falls outside `domain` — plotted nowhere, because
    /// `chartXScale` clips to its domain.
    ///
    /// The window the client asked for and the events the server returned can
    /// disagree: the harness filters `since`/`until` by *string* comparison against
    /// whatever `ingested` holds, so a differently-formatted timestamp passes the
    /// filter and still lands off-domain. Counting them is what turns "the plot
    /// is empty" into "these events sit outside this window".
    internal func outOfWindowCount(domain: ClosedRange<Date>) -> Int {
        events.count { event in
            guard let date = event.eventDate else { return false }
            return !domain.contains(date)
        }
    }
}

// MARK: - Decoding

/// Timestamps arrive as RFC3339 strings, with a null time encoded as `""`.
/// Decode is manual dictionary mapping so it can be tested against captured
/// payload shapes.
enum WikiTimelineDecoding {

    /// RFC3339 parsing, tolerant of the shapes a wiki actually contains; empty
    /// string → nil.
    ///
    /// Event times come from a raw source's `ingested` frontmatter — hand-written
    /// or written by whatever
    /// ingested it, so in practice a bare `datetime.isoformat()`
    /// (`2026-08-04T16:55:58.077734`), a space separator, or a plain date all
    /// show up. `ISO8601DateFormatter` rejects every one of those for want of a
    /// zone designator, which turned a dated event into an undated one: the feed
    /// still listed it (it renders the label regardless) and the legend still
    /// counted it (counts key off kind), but the plot skips any event with no
    /// date — so the dots silently vanished while everything around them looked
    /// fine. Assume UTC rather than dropping the value, since a wiki timestamp
    /// with no zone is one nobody chose a zone for, and being off by the local
    /// offset beats not plotting the event at all.
    static func parseDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let strict = strictRFC3339(s) { return strict }
        guard let assumedUTC = assumingUTC(s) else { return nil }
        return strictRFC3339(assumedUTC)
    }

    /// RFC3339 with and without fractional seconds — the well-formed cases.
    private static func strictRFC3339(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Rewrite a zone-less timestamp into an RFC3339 one, or nil when the input
    /// isn't that shape.
    ///
    /// Returns nil rather than a guess when a zone is already present: reaching
    /// here means the strict parse failed for some *other* reason, and appending
    /// `Z` to something already zoned would invent a second designator.
    private static func assumingUTC(_ s: String) -> String? {
        // A space separator is legal RFC3339 (section 5.6 "NOTE") but not
        // accepted by ISO8601DateFormatter.
        var body = s
        if let space = body.firstIndex(of: " ") {
            body.replaceSubrange(space...space, with: "T")
        }
        guard let timeStart = body.firstIndex(of: "T") else {
            // Date-only: midnight UTC. Length-checked so a stray token can't
            // become a date.
            return body.count == 10 ? body + "T00:00:00Z" : nil
        }
        let time = body[body.index(after: timeStart)...]
        let hasZone = time.contains("Z") || time.contains("+") || time.contains("-")
        return hasZone ? nil : body + "Z"
    }

    static func mapEventTimeline(_ obj: [String: Any]) -> WikiEventTimeline {
        let rawEvents = (obj["events"] as? [[String: Any]]) ?? []
        let events = rawEvents.compactMap(mapEvent)
        let byKind = (obj["events_by_kind"] as? [String: Any])?
            .compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:]
        return WikiEventTimeline(
            since: parseDate(obj["since"]),
            until: parseDate(obj["until"]),
            eventCount: (obj["event_count"] as? NSNumber)?.intValue ?? events.count,
            eventsByKind: byKind,
            events: events
        )
    }

    static func mapEvent(_ e: [String: Any]) -> WikiTimelineEvent? {
        guard let sourceKey = e["source_key"] as? String else { return nil }
        let occurredAt = parseDate(e["occurred_at"])
        let ingestedAt = parseDate(e["ingested_at"])
        return WikiTimelineEvent(
            sourceKey: sourceKey,
            kindRaw: (e["kind"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "other",
            label: e["label"] as? String ?? sourceKey,
            url: e["url"] as? String ?? "",
            occurredAt: occurredAt,
            ingestedAt: ingestedAt,
            eventTimeEstimated: e["event_time_estimated"] as? Bool ?? (occurredAt == nil),
            actorSlackID: e["actor_slack_id"] as? String,
            actorName: e["actor_name"] as? String,
            directiveBody: e["directive_body"] as? String,
            directiveExcerpt: e["directive_excerpt"] as? String,
            targetPages: e["target_pages"] as? [String],
            directiveStatus: e["directive_status"] as? String,
            resultingRevisionIDs: (e["resulting_revision_ids"] as? [Any])?
                .compactMap { ($0 as? NSNumber)?.int64Value }
        )
    }
}
