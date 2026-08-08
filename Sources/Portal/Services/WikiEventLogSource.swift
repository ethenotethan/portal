import Foundation

// MARK: - WikiEventLogSource

/// Capability marker for wiki backends that can say what flowed IN — the
/// ingestion event log behind the event plot and feed.
///
/// Distinct from `WikiEventTimelineProviding`, which stays Centaur-only: that
/// protocol also serves the revisions timeline and pages-touched summary, both
/// backed by wiki-api endpoints Hermes has no equivalent for. Splitting the
/// event log out is what lets the plot and feed serve both backends while the
/// "knowledge accrued" pane remains Centaur enrichment. The events surface
/// gates on THIS protocol; the pane gates on the other one.
///
/// Returns `WikiEventTimeline` rather than a parallel envelope: its fields —
/// events, the resolved window, per-kind counts — are exactly what both
/// backends report and what the plot, legend, and feed consume.
@MainActor
internal protocol WikiEventLogSource: WikiSource {
    /// Ingestion events over a window.
    ///
    /// - Parameters:
    ///   - days: Trailing window in days. When non-nil it wins over
    ///     `since`/`until`, matching wiki-api's own resolution order.
    ///   - since: Window start (ignored when `days` is set).
    ///   - until: Window end (ignored when `days` is set).
    ///   - wiki: Wiki name, for backends hosting more than one. Centaur
    ///     ignores it — a client is bound to one deployment's wiki.
    func fetchEventLog(
        days: Double?,
        since: Date?,
        until: Date?,
        wiki: String?
    ) async throws -> WikiEventTimeline
}

// MARK: - Hermes conformance

/// Hermes gateway: the `wiki.events` RPC (hermes-agent#44).
extension GatewayClient: WikiEventLogSource {

    /// `wiki.events` → `WikiEventTimeline`.
    ///
    /// The RPC takes ISO instants, not a day count, so a `days` window is
    /// resolved here. It also reports no window back, so the requested bounds
    /// are echoed into the result — the plot needs a domain, and the honest
    /// domain is what we asked for.
    internal func fetchEventLog(
        days: Double?,
        since: Date?,
        until: Date?,
        wiki: String?
    ) async throws -> WikiEventTimeline {
        let formatter = ISO8601DateFormatter()
        let resolvedUntil = days != nil ? Date() : until
        let resolvedSince: Date? = {
            guard let days else { return since }
            return (resolvedUntil ?? Date()).addingTimeInterval(-days * 86_400)
        }()

        let page = try await wikiEvents(
            wiki: wiki,
            since: resolvedSince.map { formatter.string(from: $0) },
            until: resolvedUntil.map { formatter.string(from: $0) }
        )

        // Hermes reports no per-kind rollup, so derive it from the window's
        // events. Equivalent to what Centaur sends whenever the page isn't
        // truncated, and the legend is about this window either way.
        var byKind: [String: Int] = [:]
        for event in page.events where !event.kindRaw.isEmpty {
            byKind[event.kindRaw, default: 0] += 1
        }

        return WikiEventTimeline(
            since: resolvedSince,
            until: resolvedUntil,
            // `total` counts every event matching the window, which can exceed
            // the page — the header's count should be the truth, not the slice.
            eventCount: page.total,
            eventsByKind: byKind,
            events: page.events
        )
    }
}

// MARK: - Centaur conformance

/// Centaur wiki-api: delegates to the timeline endpoint it already serves.
extension CentaurWikiClient: WikiEventLogSource {

    /// One wiki per client, so `wiki` is inapplicable — the deployment's base
    /// URL already selects it.
    internal func fetchEventLog(
        days: Double?,
        since: Date?,
        until: Date?,
        wiki: String?
    ) async throws -> WikiEventTimeline {
        try await fetchEventTimeline(days: days, since: since, until: until)
    }
}
