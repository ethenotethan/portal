import Foundation

// MARK: - WikiEventTimelineProviding

/// A wiki source that can serve the Compendium ingestion timeline. The UI
/// gates the "Events" surface by this conformance — only Centaur's wiki-api
/// exposes these endpoints (Hermes GatewayClient deliberately does NOT
/// conform, so Hermes wikis never show the button).
@MainActor
protocol WikiEventTimelineProviding: AnyObject {
    /// `GET /wiki/timeline` — raw input events over the window.
    func fetchEventTimeline(days: Double?, since: Date?, until: Date?) async throws -> WikiEventTimeline
    /// `GET /wiki/revisions-timeline` — bucketed page-edit volume + baseline.
    func fetchRevisionsTimeline(days: Double?, since: Date?, until: Date?) async throws -> WikiRevisionsTimeline
}

// MARK: - CentaurWikiClient conformance

extension CentaurWikiClient: WikiEventTimelineProviding {

    /// /wiki/timeline → WikiEventTimeline. Window params mirror the server's
    /// resolution order: `days` wins when present; otherwise `since`/`until`
    /// (RFC3339) with server defaults (last 24h) for whichever is missing.
    func fetchEventTimeline(
        days: Double? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> WikiEventTimeline {
        let obj = try await getJSON(Self.timelinePath("wiki/timeline", days: days, since: since, until: until))
        return WikiTimelineDecoding.mapEventTimeline(obj)
    }

    /// /wiki/revisions-timeline → WikiRevisionsTimeline. Same window params.
    func fetchRevisionsTimeline(
        days: Double? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) async throws -> WikiRevisionsTimeline {
        let obj = try await getJSON(
            Self.timelinePath("wiki/revisions-timeline", days: days, since: since, until: until)
        )
        return WikiTimelineDecoding.mapRevisionsTimeline(obj)
    }

    /// Builds "path?days=…" / "path?since=…&until=…". Static + nonisolated
    /// for direct unit testing of the query formatting.
    nonisolated static func timelinePath(
        _ path: String,
        days: Double?,
        since: Date?,
        until: Date?
    ) -> String {
        var items: [URLQueryItem] = []
        if let days {
            // Trim "7.0" → "7"; keep fractional windows ("0.5") intact.
            let formatted = days == days.rounded() && abs(days) < 1e15
                ? String(Int(days))
                : String(days)
            items.append(URLQueryItem(name: "days", value: formatted))
        } else {
            let iso = ISO8601DateFormatter()
            if let since { items.append(URLQueryItem(name: "since", value: iso.string(from: since))) }
            if let until { items.append(URLQueryItem(name: "until", value: iso.string(from: until))) }
        }
        guard !items.isEmpty else { return path }
        var components = URLComponents()
        components.queryItems = items
        return "\(path)?\(components.percentEncodedQuery ?? "")"
    }
}
