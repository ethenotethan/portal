import Testing
import SwiftUI
import Foundation
@testable import Portal

// MARK: - Fixtures

/// Payloads shaped like hermes-agent's `wiki_events` handler (#44): every event
/// is a raw source file, `timestamp` is the frontmatter `ingested` value (or the
/// file mtime), and `changesets` is the join back to the pages the event edited.
private enum Fixtures {

    /// A fully-populated entry: title, kind, url, digest, two changesets.
    static let full: AnyCodable = .dictionary([
        "key": AnyCodable("raw/github/pr-1234.md"),
        "kind": AnyCodable("github_pr"),
        "title": AnyCodable("fix: health probe dialed the wrong port"),
        "timestamp": AnyCodable("2026-07-20T15:00:00Z"),
        "source_url": AnyCodable("https://github.com/org/repo/pull/1234"),
        "sha256": AnyCodable("a1b2c3d4e5f60718293a4b5c6d7e8f90"),
        "changesets": .array([
            .dictionary([
                "id": AnyCodable("cs-1"),
                "page": AnyCodable("topics/health-probes.md"),
                "title": AnyCodable("Health probes"),
                "action": AnyCodable("update"),
                "timestamp": AnyCodable("2026-07-20T15:01:00Z"),
            ]),
            .dictionary([
                "id": AnyCodable("cs-2"),
                "page": AnyCodable("topics/deploy-checklist.md"),
                "title": AnyCodable(""),
                "action": AnyCodable("create"),
                "timestamp": AnyCodable(""),
            ]),
        ]),
    ])

    /// The sparse case a pre-#44 wiki produces: no title, no digest, no
    /// changesets, and a kind the wiki hasn't declared.
    static let bare: AnyCodable = .dictionary([
        "key": AnyCodable("raw/notes/2026-06-04-standup.md"),
        "kind": AnyCodable("meeting_notes"),
        "timestamp": AnyCodable("2026-06-04T09:00:00Z"),
    ])

    /// No key — the gateway shouldn't send this, and a row without an identity
    /// can't be selected or plotted, so it must be dropped rather than rendered.
    static let keyless: AnyCodable = .dictionary([
        "kind": AnyCodable("github_pr"),
        "title": AnyCodable("orphan"),
    ])
}

// MARK: - wiki.events decoding

@Suite("wiki.events decoding")
internal struct WikiEventLogDecodingTests {

    @Test("full entry: key, kind, title, url, digest, both times from one field")
    internal func decodesFullEntry() throws {
        let event = try #require(GatewayClient.eventLogEntry(from: Fixtures.full))
        #expect(event.sourceKey == "raw/github/pr-1234.md")
        #expect(event.id == "raw/github/pr-1234.md")
        #expect(event.kindRaw == "github_pr")
        #expect(event.label == "fix: health probe dialed the wrong port")
        #expect(event.url == "https://github.com/org/repo/pull/1234")
        #expect(event.sha256 == "a1b2c3d4e5f60718293a4b5c6d7e8f90")
        // Hermes reports one instant, so occurred == ingested and the
        // estimated-time flag stays false — a diamond here would claim we
        // substituted ingest time for a known event time, which we didn't.
        let expected = WikiTimelineDecoding.parseDate("2026-07-20T15:00:00Z")
        #expect(event.occurredAt == expected)
        #expect(event.ingestedAt == expected)
        #expect(event.eventTimeEstimated == false)
    }

    @Test("changesets decode in order, with page/action and a nil bad timestamp")
    internal func decodesChangesets() throws {
        let event = try #require(GatewayClient.eventLogEntry(from: Fixtures.full))
        #expect(event.changesets.count == 2)

        let first = event.changesets[0]
        #expect(first.id == "cs-1")
        #expect(first.page == "topics/health-probes.md")
        #expect(first.action == "update")
        #expect(first.pageLabel == "Health probes")
        #expect(first.timestamp == WikiTimelineDecoding.parseDate("2026-07-20T15:01:00Z"))

        // No title: the chip label falls back to the path's last component, so
        // the button is never blank.
        let second = event.changesets[1]
        #expect(second.pageLabel == "deploy-checklist.md")
        #expect(second.timestamp == nil)
    }

    @Test("no title: label falls back to the key's short label, not empty")
    internal func decodesBareEntry() throws {
        let event = try #require(GatewayClient.eventLogEntry(from: Fixtures.bare))
        #expect(event.label == "2026-06-04-standup")
        #expect(event.sha256.isEmpty)
        #expect(event.changesets.isEmpty)
        #expect(event.url.isEmpty)
    }

    @Test("entry without a key is dropped")
    internal func dropsKeylessEntry() {
        #expect(GatewayClient.eventLogEntry(from: Fixtures.keyless) == nil)
    }

    @Test("changeset entries without an id are dropped, siblings kept")
    internal func dropsIDlessChangeset() throws {
        let item: AnyCodable = .dictionary([
            "key": AnyCodable("raw/x.md"),
            "changesets": .array([
                .dictionary(["page": AnyCodable("a.md")]),
                .dictionary(["id": AnyCodable("cs-9"), "page": AnyCodable("b.md")]),
            ]),
        ])
        let event = try #require(GatewayClient.eventLogEntry(from: item))
        #expect(event.changesets.map(\.id) == ["cs-9"])
    }

    @Test("hasMore is offset+page vs total, not page-size arithmetic")
    internal func paginationFlag() {
        let events = [GatewayClient.eventLogEntry(from: Fixtures.bare)].compactMap { $0 }
        let mid = WikiEventLogPage(events: events, total: 10, offset: 0)
        #expect(mid.hasMore)
        let last = WikiEventLogPage(events: events, total: 10, offset: 9)
        #expect(!last.hasMore)
    }
}

// MARK: - WikiEventPresentation

@Suite("WikiEventPresentation")
internal struct WikiEventPresentationTests {

    /// A registry with one declared kind, built the way the taxonomy loader
    /// does: a definition page plus its frontmatter.
    private func registry(kind: String, color: String, lane: String) -> WikiEventTypeRegistry {
        let page = WikiPage(
            id: kind, title: "Declared \(kind)",
            type: WikiEventTypeRegistry.definitionPageType, tags: [],
            path: "event-types/\(kind).md", created: nil, updated: nil,
            confidence: nil, contested: false, tagPath: [], integrationLinks: []
        )
        return WikiEventTypeRegistry.build(pages: [page]) { _ in
            ["event_kind": kind, "color": color, "lane": lane]
        }
    }

    @Test("a declared kind wins over the built-in palette")
    internal func declaredBeatsBuiltIn() {
        // github_pr IS in the built-in palette; the wiki redefining it must win,
        // else a Hermes wiki can't actually own its own taxonomy.
        let p = WikiEventPresentation(registry: registry(kind: "github_pr", color: "#ff0000", lane: "5"))
        #expect(p.label(for: "github_pr") == "Declared github_pr")
        #expect(p.color(for: "github_pr") == Color(hex: "ff0000"))
        #expect(p.pagePath(for: "github_pr") == "event-types/github_pr.md")
    }

    @Test("an undeclared built-in kind uses the validated palette and has no page")
    internal func builtInFallback() {
        let p = WikiEventPresentation.empty
        #expect(p.label(for: "github_pr") == WikiEventKind.githubPR.displayName)
        #expect(p.color(for: "github_pr") == WikiEventKindStyle.color(for: .githubPR))
        // Nothing to open — a chip that looks live but goes nowhere is worse
        // than plain text.
        #expect(p.pagePath(for: "github_pr") == nil)
    }

    @Test("an unrecognized kind stays distinct rather than merging into 'other'")
    internal func derivedKindsStayDistinct() {
        let p = WikiEventPresentation.empty
        #expect(p.color(for: "linear_issue") != p.color(for: "notion_doc"))
        #expect(p.label(for: "meeting_notes") != "Unclassified")
    }

    @Test("an empty kind is unclassified, not a confident derived hue")
    internal func emptyKindIsUnclassified() {
        let p = WikiEventPresentation.empty
        #expect(p.label(for: "") == "Unclassified")
        #expect(p.color(for: "") == WikiEventKindStyle.color(for: .other))
        #expect(p.label(for: "   ") == "Unclassified")
    }

    @Test("lanes: declared first, then palette order, then the rest — and stable")
    internal func laneOrdering() throws {
        let p = WikiEventPresentation(registry: registry(kind: "ingest", color: "#00ff00", lane: "2"))
        let present = ["zulu_source", "slack", "ingest", "github_pr"]
        let lanes = p.lanes(present: present)
        #expect(lanes.first == "ingest")
        // Palette order, not alphabetical: github_pr precedes slack.
        let pr = try #require(lanes.firstIndex(of: "github_pr"))
        let slack = try #require(lanes.firstIndex(of: "slack"))
        #expect(pr < slack)
        #expect(lanes.last == "zulu_source")
        // Order can't depend on input order, or the plot reshuffles between
        // loads and becomes unreadable.
        #expect(p.lanes(present: present.reversed()) == lanes)
    }

    @Test("lanes deduplicate: one row per kind however many events carry it")
    internal func lanesDeduplicate() {
        let p = WikiEventPresentation.empty
        #expect(p.lanes(present: ["slack", "slack", "slack"]) == ["slack"])
    }
}

// MARK: - Window resolution and rollup

@Suite("WikiEventLogWindow")
internal struct WikiEventLogWindowTests {

    /// A fixed instant, so the assertions are exact rather than a tolerance.
    private static let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test("a days window is measured back from now and wins over explicit bounds")
    internal func daysWindowResolves() {
        // The stale bounds must be discarded, not merged: wiki-api resolves
        // `days` first, and a client that blended them would ask for a window
        // neither side intended.
        let stale = Date(timeIntervalSince1970: 1_600_000_000)
        let window = WikiEventLogWindow.resolve(
            days: 30, since: stale, until: stale, now: Self.now
        )
        #expect(window.until == Self.now)
        #expect(window.since == Self.now.addingTimeInterval(-30 * 86_400))
    }

    @Test("without days, the caller's bounds pass through untouched")
    internal func explicitBoundsPassThrough() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let until = Date(timeIntervalSince1970: 1_710_000_000)
        let window = WikiEventLogWindow.resolve(
            days: nil, since: since, until: until, now: Self.now
        )
        #expect(window.since == since)
        #expect(window.until == until)
    }

    @Test("no days and no bounds asks for the whole log, not a window around now")
    internal func unboundedRequest() {
        let window = WikiEventLogWindow.resolve(
            days: nil, since: nil, until: nil, now: Self.now
        )
        #expect(window.since == nil)
        #expect(window.until == nil)
    }

    @Test("a fractional day window resolves without rounding to whole days")
    internal func fractionalDays() {
        // The events page's ladder is whole days, but the protocol takes a
        // Double and callers-to-be may pass hours.
        let window = WikiEventLogWindow.resolve(
            days: 0.5, since: nil, until: nil, now: Self.now
        )
        #expect(window.since == Self.now.addingTimeInterval(-43_200))
    }

    @Test("countByKind rolls up the window's events, skipping blank kinds")
    internal func derivesKindRollup() {
        // Hermes sends no per-kind rollup, so the legend's counts come from the
        // decoded events. A blank kind isn't a category — counting it would put
        // a nameless row in the legend.
        let items: [AnyCodable] = [
            .dictionary(["key": AnyCodable("a"), "kind": AnyCodable("github_pr")]),
            .dictionary(["key": AnyCodable("b"), "kind": AnyCodable("github_pr")]),
            .dictionary(["key": AnyCodable("c"), "kind": AnyCodable("ingest")]),
            .dictionary(["key": AnyCodable("d")]),
        ]
        let events = items.compactMap { GatewayClient.eventLogEntry(from: $0) }
        #expect(events.count == 4)
        #expect(WikiEventLogWindow.countByKind(events) == ["github_pr": 2, "ingest": 1])
    }

    @Test("countByKind of nothing is empty, not a zero-valued row")
    internal func emptyRollup() {
        #expect(WikiEventLogWindow.countByKind([]).isEmpty)
    }

    @Test("wireBounds renders the window as ISO instants the RPC accepts")
    internal func wireBoundsRenderISO() throws {
        let wire = WikiEventLogWindow.wireBounds(
            days: 30, since: nil, until: nil, now: Self.now
        )
        let until = try #require(wire.until)
        let since = try #require(wire.since)
        // Round-trip rather than string-match: the assertion is "the gateway can
        // parse this back to the instant we meant", not a format preference.
        let parser = ISO8601DateFormatter()
        #expect(parser.date(from: until) == Self.now)
        #expect(parser.date(from: since) == Self.now.addingTimeInterval(-30 * 86_400))
    }

    @Test("an unbounded window stays nil on the wire, never an empty string")
    internal func wireBoundsStayNil() {
        // "" is an unparseable bound, not an absent one — it would narrow a
        // query the caller meant to leave open.
        let wire = WikiEventLogWindow.wireBounds(
            days: nil, since: nil, until: nil, now: Self.now
        )
        #expect(wire.since == nil)
        #expect(wire.until == nil)
    }

    @Test("timeline echoes the requested window as the plot domain and total as the count")
    internal func timelineEchoesWindow() throws {
        let events = [Fixtures.full, Fixtures.bare].compactMap { GatewayClient.eventLogEntry(from: $0) }
        let page = WikiEventLogPage(events: events, total: 99, offset: 0)
        let timeline = WikiEventLogWindow.timeline(
            page: page, days: 7, since: nil, until: nil, now: Self.now
        )
        #expect(timeline.until == Self.now)
        #expect(timeline.since == Self.now.addingTimeInterval(-7 * 86_400))
        // total, not events.count: the header should report the window's truth,
        // not the size of the slice that fit in one page.
        #expect(timeline.eventCount == 99)
        #expect(timeline.events.count == 2)
        #expect(timeline.eventsByKind == ["github_pr": 1, "meeting_notes": 1])
    }
}

// MARK: - wiki.events request params

@Suite("wiki.events params")
internal struct WikiEventLogParamsTests {

    @Test("nil filters are omitted, not sent as empty values")
    internal func omitsNilFilters() {
        let params = GatewayClient.eventLogParams(
            wiki: nil, kind: nil, since: nil, until: nil, limit: 200, offset: 0
        )
        #expect(Set(params.keys) == ["limit", "offset"])
        #expect(params["limit"]?.intValue == 200)
        #expect(params["offset"]?.intValue == 0)
    }

    @Test("every provided filter reaches the wire under its wire name")
    internal func sendsProvidedFilters() {
        let params = GatewayClient.eventLogParams(
            wiki: "hermes", kind: "github_pr",
            since: "2026-07-01T00:00:00Z", until: "2026-07-31T00:00:00Z",
            limit: 50, offset: 100
        )
        #expect(params["wiki"]?.stringValue == "hermes")
        #expect(params["kind"]?.stringValue == "github_pr")
        #expect(params["since"]?.stringValue == "2026-07-01T00:00:00Z")
        #expect(params["until"]?.stringValue == "2026-07-31T00:00:00Z")
        #expect(params["limit"]?.intValue == 50)
        #expect(params["offset"]?.intValue == 100)
    }
}

// MARK: - wiki.events page decoding

@Suite("wiki.events page decoding")
internal struct WikiEventLogPageTests {

    @Test("decodes events, total, and offset from the result envelope")
    internal func decodesPage() throws {
        let result: AnyCodable = .dictionary([
            "events": .array([Fixtures.full, Fixtures.bare]),
            "total": AnyCodable(42),
            "offset": AnyCodable(10),
        ])
        let page = try GatewayClient.eventLogPage(from: result, offset: 0)
        #expect(page.events.count == 2)
        #expect(page.total == 42)
        // The server's echo wins over the request's offset.
        #expect(page.offset == 10)
        #expect(page.hasMore)
    }

    @Test("keyless rows are dropped from the page, not rendered blank")
    internal func dropsKeylessRows() throws {
        let result: AnyCodable = .dictionary([
            "events": .array([Fixtures.full, Fixtures.keyless, Fixtures.bare]),
        ])
        let page = try GatewayClient.eventLogPage(from: result, offset: 0)
        #expect(page.events.count == 2)
        // total omitted: falls back to what arrived, so hasMore stays false
        // rather than promising a page that doesn't exist.
        #expect(page.total == 2)
        #expect(!page.hasMore)
    }

    @Test("a missing offset falls back to the requested one, keeping hasMore honest")
    internal func offsetFallback() throws {
        let result: AnyCodable = .dictionary([
            "events": .array([Fixtures.bare]),
            "total": AnyCodable(51),
        ])
        let page = try GatewayClient.eventLogPage(from: result, offset: 50)
        #expect(page.offset == 50)
        // 50 + 1 == 51: this is the last page. Defaulting the offset to 0 would
        // have claimed there was more.
        #expect(!page.hasMore)
    }

    @Test("an empty events array is a valid empty page, not an error")
    internal func emptyPage() throws {
        let page = try GatewayClient.eventLogPage(from: .dictionary(["events": .array([])]), offset: 0)
        #expect(page.events.isEmpty)
        #expect(page.total == 0)
        #expect(!page.hasMore)
    }

    @Test("a result with no events array throws rather than showing an empty log")
    internal func missingEventsArrayThrows() {
        // "the call failed" and "the wiki has no events" must not look alike.
        #expect(throws: GatewayError.self) {
            _ = try GatewayClient.eventLogPage(from: .dictionary(["total": AnyCodable(3)]), offset: 0)
        }
        #expect(throws: GatewayError.self) {
            _ = try GatewayClient.eventLogPage(from: nil, offset: 0)
        }
    }
}

// MARK: - Changeset → event navigation

@MainActor
@Suite("changeset → event feed navigation")
internal struct WikiEventFocusTests {

    @Test("openEventFeed focuses the key, opens the page, closes the drawer")
    internal func openEventFeedSwapsSurface() {
        let viewModel = WikiGraphViewModel()
        viewModel.showTimeline = true
        viewModel.openEventFeed(eventKey: "raw/github/pr-1234.md")
        #expect(viewModel.focusedEventKey == "raw/github/pr-1234.md")
        #expect(viewModel.showEventsPage)
        // The events page owns the whole surface; a drawer left open beneath it
        // would fight for the same space.
        #expect(!viewModel.showTimeline)
    }

    @Test("openPageLeavingEvents is the reverse edge and leaves the events page")
    internal func openPageLeavingEventsReturns() {
        let viewModel = WikiGraphViewModel()
        viewModel.showEventsPage = true
        viewModel.openPageLeavingEvents("topics/health-probes.md")
        #expect(!viewModel.showEventsPage)
        #expect(viewModel.selectedPath == "topics/health-probes.md")
    }
}
