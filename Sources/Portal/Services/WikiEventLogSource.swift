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

// MARK: - Window and rollup arithmetic

/// The pure parts of the Hermes conformance, lifted out of the async transport
/// so they're reachable by a test.
///
/// `fetchEventLog` is one round-trip wrapped around these two decisions, and
/// they're where the behavior actually lives: which instants get asked for, and
/// what the legend counts. Leaving them inline would mean the only way to check
/// them is to restate the arithmetic in a test — which passes whether or not
/// the code is right.
internal enum WikiEventLogWindow {

    /// Resolve a request into the ISO bounds `wiki.events` takes.
    ///
    /// A `days` window wins over explicit bounds, matching wiki-api's own
    /// resolution order, and is measured back from `now` so "last 30 days"
    /// means what it says. With no `days`, the caller's bounds pass through
    /// untouched — including both-nil, which asks for the whole log.
    ///
    /// - Parameter now: Injected rather than read, so a test can assert exact
    ///   instants instead of a tolerance.
    internal static func resolve(
        days: Double?,
        since: Date?,
        until: Date?,
        now: Date
    ) -> (since: Date?, until: Date?) {
        guard let days else { return (since, until) }
        let resolvedUntil = now
        return (resolvedUntil.addingTimeInterval(-days * 86_400), resolvedUntil)
    }

    /// The same window as the ISO strings the RPC takes.
    ///
    /// A nil bound stays nil rather than becoming an empty string: `wiki.events`
    /// treats an absent bound as unbounded, and `""` as an unparseable one.
    internal static func wireBounds(
        days: Double?,
        since: Date?,
        until: Date?,
        now: Date
    ) -> (since: String?, until: String?) {
        let formatter = ISO8601DateFormatter()
        let window = resolve(days: days, since: since, until: until, now: now)
        return (
            window.since.map { formatter.string(from: $0) },
            window.until.map { formatter.string(from: $0) }
        )
    }

    /// Per-kind counts for the legend.
    ///
    /// Hermes sends no rollup, so it's derived from the window's events —
    /// equivalent to what Centaur sends whenever the page isn't truncated, and
    /// the legend is about this window either way. A blank kind isn't a
    /// category, so it isn't counted: it would render as a nameless legend row.
    internal static func countByKind(_ events: [WikiTimelineEvent]) -> [String: Int] {
        var byKind: [String: Int] = [:]
        for event in events where !event.kindRaw.isEmpty {
            byKind[event.kindRaw, default: 0] += 1
        }
        return byKind
    }

    /// Assemble a page into the timeline the plot, legend, and feed consume.
    ///
    /// The requested bounds are echoed back as the plot's x-domain because the
    /// RPC reports no window of its own — a chart needs a domain, and the honest
    /// one is what we asked for. Resolved from the same inputs and the same
    /// `now` as the request, so the domain can't drift from the window fetched.
    internal static func timeline(
        page: WikiEventLogPage,
        days: Double?,
        since: Date?,
        until: Date?,
        now: Date
    ) -> WikiEventTimeline {
        let window = resolve(days: days, since: since, until: until, now: now)
        return WikiEventTimeline(
            since: window.since,
            until: window.until,
            // `total` counts every event matching the window, which can exceed
            // the page — the header's count should be the truth, not the slice.
            eventCount: page.total,
            eventsByKind: countByKind(page.events),
            events: page.events
        )
    }
}

// MARK: - Hermes conformance

/// Hermes gateway: the `wiki.events` RPC (hermes-agent#44).
extension GatewayClient: WikiEventLogSource {

    /// `wiki.events` → `WikiEventTimeline`.
    ///
    /// The RPC takes ISO instants, not a day count, and reports no window back,
    /// so the bounds are resolved here and echoed into the result — the plot
    /// needs a domain, and the honest domain is what we asked for.
    internal func fetchEventLog(
        days: Double?,
        since: Date?,
        until: Date?,
        wiki: String?
    ) async throws -> WikiEventTimeline {
        let now = Date()
        let wire = WikiEventLogWindow.wireBounds(
            days: days, since: since, until: until, now: now
        )
        let page = try await wikiEvents(wiki: wiki, since: wire.since, until: wire.until)
        return WikiEventLogWindow.timeline(
            page: page, days: days, since: since, until: until, now: now
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
