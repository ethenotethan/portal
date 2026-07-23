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

// MARK: - WikiTimelineEvent

/// One raw INPUT event that flowed into the LLM-synthesized Compendium —
/// a row from wiki-api `GET /wiki/timeline`. Directive rows carry extra
/// attribution (actor + verbatim quote + target pages); the fields are nil
/// for every other kind.
struct WikiTimelineEvent: Identifiable, Hashable {
    let sourceKey: String
    /// Wire kind string, preserved for display of unknown kinds.
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

    var id: String { sourceKey }
    var kind: WikiEventKind { WikiEventKind(wire: kindRaw) }
    /// The plotted time: real-world event time, falling back to ingest time.
    var eventDate: Date? { occurredAt ?? ingestedAt }
    var isDirective: Bool { kind == .directive }
}

// MARK: - WikiEventTimeline (GET /wiki/timeline)

/// Response of wiki-api `GET /wiki/timeline`: every ingested source as an
/// event on a single event-time axis, plus per-kind counts for the legend.
struct WikiEventTimeline {
    let since: Date?
    let until: Date?
    let eventCount: Int
    /// Wire-kind string → count (e.g. "github_pr": 40).
    let eventsByKind: [String: Int]
    let events: [WikiTimelineEvent]
}

// MARK: - WikiRevisionsTimeline (GET /wiki/revisions-timeline)

/// Response of wiki-api `GET /wiki/revisions-timeline`: page-edit volume
/// bucketed over time — the stateful OUTPUT counterpart to the raw input
/// events. `baseline` is the cumulative revision count BEFORE the window,
/// so a cumulative "knowledge accrued" curve seeds at the right height.
struct WikiRevisionsTimeline {
    /// date_trunc unit the server chose for the window: hour/day/week/month.
    let unit: String
    let since: Date?
    let until: Date?
    let baseline: Int
    let totalInWindow: Int
    let buckets: [Bucket]

    struct Bucket: Identifiable, Hashable {
        let bucket: Date?
        let count: Int
        var id: Date { bucket ?? .distantPast }
    }

    /// Buckets annotated with the running cumulative total (baseline-seeded),
    /// ready for the "knowledge accrued" curve.
    var cumulativePoints: [(bucket: Date, total: Int)] {
        var running = baseline
        return buckets.compactMap { b in
            guard let date = b.bucket else { return nil }
            running += b.count
            return (date, running)
        }
    }

    /// All-time revision count as of the window's end: what the cumulative
    /// curve tops out at. This is the headline "knowledge accrued" number.
    var totalAllTime: Int { baseline + totalInWindow }

    /// The bucket with the most edits in the window (nil when empty) — the
    /// "busiest \(unit)" stat tile. Ties break to the most recent bucket.
    var busiestBucket: Bucket? {
        buckets.filter { $0.bucket != nil && $0.count >= 1 }
            .max { ($0.count, $0.bucket ?? .distantPast) < ($1.count, $1.bucket ?? .distantPast) }
    }
}

// MARK: - WikiChangesSummary (GET /wiki/changes)

/// Page-level slice of wiki-api `GET /wiki/changes`: which wiki pages were
/// created/updated in the window (anchored on EVENT time, per the handler's
/// backfill-alignment comment), plus per-type counts. The response also
/// carries a `sources` array, but that duplicates `/wiki/timeline` with less
/// enrichment — the feed uses the timeline; this summary feeds the
/// "knowledge accrued" pane (pages touched + updated-page links).
struct WikiChangesSummary {
    let since: Date?
    let until: Date?
    let pageCount: Int
    /// Page type ("topic", "entity", …) → count in window.
    let pagesByType: [String: Int]
    let pages: [PageChange]

    struct PageChange: Identifiable, Hashable {
        /// Document id ("wiki:topic:glossary-mcp") — doubles as the wiki
        /// page path for the shared selection plane.
        let id: String
        let title: String
        let type: String
        let url: String
        let updatedAt: Date?
    }
}

// MARK: - Decoding

/// The wiki-api serializes timestamps as RFC3339 strings and encodes a null
/// time as `""` (its `iso()` helper `unwrap_or_default`s). Decode is manual
/// dictionary mapping — consistent with CentaurWikiClient's other endpoints
/// and testable against captured payload shapes.
enum WikiTimelineDecoding {

    /// Fractional-second-tolerant RFC3339 parsing; empty string → nil.
    static func parseDate(_ value: Any?) -> Date? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
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

    static func mapChangesSummary(_ obj: [String: Any]) -> WikiChangesSummary {
        let rawPages = (obj["pages"] as? [[String: Any]]) ?? []
        let pages: [WikiChangesSummary.PageChange] = rawPages.compactMap { p in
            guard let id = p["id"] as? String else { return nil }
            return WikiChangesSummary.PageChange(
                id: id,
                title: p["title"] as? String ?? id,
                type: p["type"] as? String ?? "topic",
                url: p["url"] as? String ?? "",
                updatedAt: parseDate(p["updated_at"])
            )
        }
        let byType = (obj["pages_by_type"] as? [String: Any])?
            .compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:]
        return WikiChangesSummary(
            since: parseDate(obj["since"]),
            until: parseDate(obj["until"]),
            pageCount: (obj["page_count"] as? NSNumber)?.intValue ?? pages.count,
            pagesByType: byType,
            pages: pages
        )
    }

    static func mapRevisionsTimeline(_ obj: [String: Any]) -> WikiRevisionsTimeline {
        let rawBuckets = (obj["buckets"] as? [[String: Any]]) ?? []
        let buckets = rawBuckets.map { b in
            WikiRevisionsTimeline.Bucket(
                bucket: parseDate(b["bucket"]),
                count: (b["count"] as? NSNumber)?.intValue ?? 0
            )
        }
        return WikiRevisionsTimeline(
            unit: obj["unit"] as? String ?? "day",
            since: parseDate(obj["since"]),
            until: parseDate(obj["until"]),
            baseline: (obj["baseline"] as? NSNumber)?.intValue ?? 0,
            totalInWindow: (obj["total_in_window"] as? NSNumber)?.intValue ?? 0,
            buckets: buckets
        )
    }
}
