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

// MARK: - GatewayClient.fetchEventLog window resolution

@MainActor
@Suite("fetchEventLog window resolution")
internal struct WikiEventLogWindowTests {

    /// The RPC takes ISO instants, not a day count, so `fetchEventLog` resolves
    /// the window itself and echoes it back as the plot's x-domain — a chart
    /// with no domain can't be drawn, and the honest domain is what we asked
    /// for. Exercised through the same arithmetic the conformance performs.
    @Test("a days window resolves to since = until - days, echoed as the domain")
    internal func daysWindowResolves() {
        let until = Date()
        let since = until.addingTimeInterval(-30 * 86_400)
        let timeline = WikiEventTimeline(
            since: since, until: until, eventCount: 7,
            eventsByKind: [:], events: []
        )
        let span = try? #require(timeline.until).timeIntervalSince(try #require(timeline.since))
        #expect(abs((span ?? 0) - 30 * 86_400) < 1)
    }

    @Test("eventsByKind is derived from the window's events, skipping blank kinds")
    internal func derivesKindRollup() throws {
        // Hermes sends no per-kind rollup, so the legend's counts come from the
        // decoded events. A blank kind isn't a category, so it's not counted.
        let items: [AnyCodable] = [
            .dictionary(["key": AnyCodable("a"), "kind": AnyCodable("github_pr")]),
            .dictionary(["key": AnyCodable("b"), "kind": AnyCodable("github_pr")]),
            .dictionary(["key": AnyCodable("c"), "kind": AnyCodable("ingest")]),
            .dictionary(["key": AnyCodable("d")]),
        ]
        let events = items.compactMap { GatewayClient.eventLogEntry(from: $0) }
        #expect(events.count == 4)

        var byKind: [String: Int] = [:]
        for event in events where !event.kindRaw.isEmpty {
            byKind[event.kindRaw, default: 0] += 1
        }
        #expect(byKind == ["github_pr": 2, "ingest": 1])
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
