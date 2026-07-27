import Testing
import Foundation
@testable import HermesNative

// MARK: - Fixtures

/// Sample payloads mirroring wiki-api's `wiki_timeline` /
/// `wiki_revisions_timeline` handlers (services/wiki-api/src/wiki.rs):
/// timestamps are RFC3339, null times serialize as `""`, directive rows
/// carry the enrichment columns and other kinds carry JSON nulls.
private enum Fixtures {
    static let eventTimelineJSON = """
    {
      "since": "2026-06-23T00:00:00Z",
      "until": "2026-07-23T00:00:00Z",
      "event_count": 3,
      "events_by_kind": {"github_pr": 1, "directive": 1, "meeting_notes": 1},
      "events": [
        {
          "source_key": "github:pr:1234",
          "kind": "github_pr",
          "label": "fix: health probe dialed the wrong port",
          "url": "https://github.com/org/repo/pull/1234",
          "occurred_at": "2026-07-20T14:30:00Z",
          "ingested_at": "2026-07-20T15:00:00.123456Z",
          "event_time_estimated": false,
          "actor_slack_id": null,
          "actor_name": null,
          "directive_body": null,
          "directive_excerpt": null,
          "target_pages": null,
          "directive_status": null,
          "resulting_revision_ids": null
        },
        {
          "source_key": "slack:directive:C123:1721400000.000100",
          "kind": "directive",
          "label": "always list the glossary pages first",
          "url": "",
          "occurred_at": "2026-07-19T09:12:00Z",
          "ingested_at": "2026-07-19T09:13:00Z",
          "event_time_estimated": false,
          "actor_slack_id": "U0AGENT",
          "actor_name": "Greg",
          "directive_body": "always list the glossary pages first when summarizing",
          "directive_excerpt": "always list the glossary pages first when summarizing",
          "target_pages": ["wiki:topic:glossary-mcp", "wiki:entity:person-greg"],
          "directive_status": "applied",
          "resulting_revision_ids": [881, 882]
        },
        {
          "source_key": "meeting:2026-07-01:standup",
          "kind": "meeting_notes",
          "label": "Standup notes",
          "url": "",
          "occurred_at": "",
          "ingested_at": "2026-07-18T08:00:00Z",
          "event_time_estimated": true,
          "actor_slack_id": null,
          "actor_name": null,
          "directive_body": null,
          "directive_excerpt": null,
          "target_pages": null,
          "directive_status": null,
          "resulting_revision_ids": null
        }
      ]
    }
    """

    static let revisionsTimelineJSON = """
    {
      "since": "2026-06-23T00:00:00Z",
      "until": "2026-07-23T00:00:00Z",
      "unit": "day",
      "baseline": 412,
      "total_in_window": 9,
      "buckets": [
        {"bucket": "2026-07-19T00:00:00Z", "count": 4},
        {"bucket": "2026-07-20T00:00:00Z", "count": 5}
      ]
    }
    """

    static let changesJSON = """
    {
      "since": "2026-06-23T00:00:00Z",
      "until": "2026-07-23T00:00:00Z",
      "page_count": 2,
      "source_count": 3,
      "pages_by_type": {"topic": 1, "entity": 1},
      "sources_by_kind": {"github_pr": 2, "slack": 1},
      "pages": [
        {
          "id": "wiki:topic:glossary-mcp",
          "title": "Glossary: MCP",
          "type": "topic",
          "url": "https://docs.example.com/wiki/glossary-mcp",
          "updated_at": "2026-07-20T14:30:00Z"
        },
        {
          "id": "wiki:entity:person-greg",
          "title": "Greg",
          "type": "entity",
          "url": "",
          "updated_at": ""
        }
      ],
      "sources": [
        {"source_key": "github:pr:1", "kind": "github_pr"}
      ]
    }
    """

    static func object(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try #require(obj)
    }
}

// MARK: - /wiki/timeline decoding

@Suite("Wiki Event Timeline Decoding")
struct WikiEventTimelineDecodingTests {

    @Test("decodes envelope: window, count, per-kind map, all events")
    func decodesEnvelope() throws {
        let timeline = WikiTimelineDecoding.mapEventTimeline(try Fixtures.object(Fixtures.eventTimelineJSON))
        #expect(timeline.eventCount == 3)
        #expect(timeline.events.count == 3)
        #expect(timeline.eventsByKind["github_pr"] == 1)
        #expect(timeline.eventsByKind["meeting_notes"] == 1)
        #expect(timeline.since != nil)
        #expect(timeline.until != nil)
    }

    @Test("plain event: kind, label, url, both timestamps, no directive fields")
    func decodesPlainEvent() throws {
        let timeline = WikiTimelineDecoding.mapEventTimeline(try Fixtures.object(Fixtures.eventTimelineJSON))
        let pr = try #require(timeline.events.first { $0.sourceKey == "github:pr:1234" })
        #expect(pr.kind == .githubPR)
        #expect(pr.label == "fix: health probe dialed the wrong port")
        #expect(pr.url == "https://github.com/org/repo/pull/1234")
        #expect(pr.occurredAt != nil)
        #expect(pr.ingestedAt != nil)   // fractional-second RFC3339 parses
        #expect(!pr.eventTimeEstimated)
        #expect(!pr.isDirective)
        #expect(pr.actorName == nil)
        #expect(pr.targetPages == nil)
        #expect(pr.resultingRevisionIDs == nil)
    }

    @Test("directive event carries actor, quote, target pages, revision ids")
    func decodesDirectiveEnrichment() throws {
        let timeline = WikiTimelineDecoding.mapEventTimeline(try Fixtures.object(Fixtures.eventTimelineJSON))
        let directive = try #require(timeline.events.first { $0.isDirective })
        #expect(directive.kind == .directive)
        #expect(directive.actorName == "Greg")
        #expect(directive.actorSlackID == "U0AGENT")
        #expect(directive.directiveExcerpt == "always list the glossary pages first when summarizing")
        #expect(directive.targetPages == ["wiki:topic:glossary-mcp", "wiki:entity:person-greg"])
        #expect(directive.directiveStatus == "applied")
        #expect(directive.resultingRevisionIDs == [881, 882])
    }

    @Test("estimated-time event: empty occurred_at → nil, falls back to ingest time")
    func decodesEstimatedTimeEvent() throws {
        let timeline = WikiTimelineDecoding.mapEventTimeline(try Fixtures.object(Fixtures.eventTimelineJSON))
        let meeting = try #require(timeline.events.first { $0.sourceKey == "meeting:2026-07-01:standup" })
        #expect(meeting.occurredAt == nil)          // "" serializes null
        #expect(meeting.eventTimeEstimated)
        #expect(meeting.eventDate == meeting.ingestedAt)
    }

    @Test("unknown kind falls back to .other but keeps the wire string")
    func unknownKindFallsBack() throws {
        let timeline = WikiTimelineDecoding.mapEventTimeline(try Fixtures.object(Fixtures.eventTimelineJSON))
        let meeting = try #require(timeline.events.first { $0.kindRaw == "meeting_notes" })
        #expect(meeting.kind == .other)
        #expect(meeting.kindRaw == "meeting_notes")
    }

    @Test("event without source_key is dropped; empty payload decodes empty")
    func toleratesMalformedRows() {
        let timeline = WikiTimelineDecoding.mapEventTimeline([
            "events": [["kind": "slack"], ["source_key": "slack:thread:1", "kind": "slack"]],
        ])
        #expect(timeline.events.count == 1)
        #expect(timeline.events[0].kind == .slack)

        let empty = WikiTimelineDecoding.mapEventTimeline([:])
        #expect(empty.events.isEmpty)
        #expect(empty.eventCount == 0)
        #expect(empty.eventsByKind.isEmpty)
    }
}

// MARK: - /wiki/revisions-timeline decoding

@Suite("Wiki Revisions Timeline Decoding")
struct WikiRevisionsTimelineDecodingTests {

    @Test("decodes unit, baseline, total, and buckets")
    func decodesRevisions() throws {
        let timeline = WikiTimelineDecoding.mapRevisionsTimeline(try Fixtures.object(Fixtures.revisionsTimelineJSON))
        #expect(timeline.unit == "day")
        #expect(timeline.baseline == 412)
        #expect(timeline.totalInWindow == 9)
        #expect(timeline.buckets.count == 2)
        #expect(timeline.buckets[0].count == 4)
        #expect(timeline.buckets[0].bucket != nil)
    }

    @Test("cumulative points seed at the baseline and run to baseline+window")
    func cumulativeSeedsAtBaseline() throws {
        let timeline = WikiTimelineDecoding.mapRevisionsTimeline(try Fixtures.object(Fixtures.revisionsTimelineJSON))
        let points = timeline.cumulativePoints
        #expect(points.count == 2)
        #expect(points.first?.total == 412 + 4)
        #expect(points.last?.total == 412 + 9)
    }

    @Test("empty payload decodes to safe defaults")
    func emptyPayload() {
        let timeline = WikiTimelineDecoding.mapRevisionsTimeline([:])
        #expect(timeline.unit == "day")
        #expect(timeline.baseline == 0)
        #expect(timeline.buckets.isEmpty)
        #expect(timeline.cumulativePoints.isEmpty)
        #expect(timeline.totalAllTime == 0)
        #expect(timeline.busiestBucket == nil)
    }

    @Test("knowledge-accrued stats: all-time total and busiest bucket")
    func knowledgeStats() throws {
        let timeline = WikiTimelineDecoding.mapRevisionsTimeline(try Fixtures.object(Fixtures.revisionsTimelineJSON))
        #expect(timeline.totalAllTime == 412 + 9)
        // Busiest bucket is the 5-edit day (2026-07-20).
        let busiest = try #require(timeline.busiestBucket)
        #expect(busiest.count == 5)
        #expect(busiest.bucket == WikiTimelineDecoding.parseDate("2026-07-20T00:00:00Z"))
    }

    @Test("busiest bucket ties break to the most recent bucket")
    func busiestTieBreak() {
        let timeline = WikiTimelineDecoding.mapRevisionsTimeline([
            "buckets": [
                ["bucket": "2026-07-19T00:00:00Z", "count": 4],
                ["bucket": "2026-07-20T00:00:00Z", "count": 4],
            ],
        ])
        #expect(timeline.busiestBucket?.bucket == WikiTimelineDecoding.parseDate("2026-07-20T00:00:00Z"))
    }
}

// MARK: - /wiki/changes decoding

@Suite("Wiki Changes Summary Decoding")
struct WikiChangesSummaryDecodingTests {

    @Test("decodes window, page count, per-type map, and page rows")
    func decodesChanges() throws {
        let summary = WikiTimelineDecoding.mapChangesSummary(try Fixtures.object(Fixtures.changesJSON))
        #expect(summary.pageCount == 2)
        #expect(summary.pages.count == 2)
        #expect(summary.pagesByType == ["topic": 1, "entity": 1])
        #expect(summary.since != nil)
        #expect(summary.until != nil)

        let glossary = try #require(summary.pages.first { $0.id == "wiki:topic:glossary-mcp" })
        #expect(glossary.title == "Glossary: MCP")
        #expect(glossary.type == "topic")
        #expect(glossary.url == "https://docs.example.com/wiki/glossary-mcp")
        #expect(glossary.updatedAt != nil)
    }

    @Test("empty url and empty updated_at decode to no-link, nil-date rows")
    func decodesBareRow() throws {
        let summary = WikiTimelineDecoding.mapChangesSummary(try Fixtures.object(Fixtures.changesJSON))
        let greg = try #require(summary.pages.first { $0.id == "wiki:entity:person-greg" })
        #expect(greg.url.isEmpty)       // no link affordance
        #expect(greg.updatedAt == nil)  // "" serializes null
    }

    @Test("page rows without an id are dropped; empty payload decodes empty")
    func toleratesMalformed() {
        let summary = WikiTimelineDecoding.mapChangesSummary([
            "pages": [["title": "orphan"], ["id": "wiki:topic:kept"]],
        ])
        #expect(summary.pages.count == 1)
        #expect(summary.pageCount == 1)

        let empty = WikiTimelineDecoding.mapChangesSummary([:])
        #expect(empty.pages.isEmpty)
        #expect(empty.pagesByType.isEmpty)
    }
}

// MARK: - Window-param formatting

@Suite("Wiki Timeline Window Params")
struct WikiTimelineWindowParamTests {

    @Test("days wins and formats whole numbers without a decimal point")
    func daysParam() {
        #expect(CentaurWikiClient.timelinePath("wiki/timeline", days: 7, since: nil, until: nil)
            == "wiki/timeline?days=7")
        #expect(CentaurWikiClient.timelinePath("wiki/timeline", days: 0.5, since: nil, until: nil)
            == "wiki/timeline?days=0.5")
        // days takes precedence over since/until (mirrors the server).
        #expect(CentaurWikiClient.timelinePath("wiki/timeline", days: 30, since: Date(), until: Date())
            == "wiki/timeline?days=30")
    }

    @Test("since/until format as RFC3339 with Z, percent-encoded")
    func sinceUntilParams() {
        let since = Date(timeIntervalSince1970: 1_750_000_000)  // 2025-06-15T15:06:40Z
        let until = Date(timeIntervalSince1970: 1_750_086_400)
        let path = CentaurWikiClient.timelinePath("wiki/revisions-timeline", days: nil, since: since, until: until)
        #expect(path == "wiki/revisions-timeline?since=2025-06-15T15:06:40Z&until=2025-06-16T15:06:40Z")
    }

    @Test("no params yields the bare path")
    func bareParams() {
        #expect(CentaurWikiClient.timelinePath("wiki/timeline", days: nil, since: nil, until: nil)
            == "wiki/timeline")
    }
}

// MARK: - Events-page navigation state

@Suite("Wiki Events Page Navigation")
@MainActor
struct WikiEventsPageNavigationTests {

    @Test("Opening a page from the events surface returns to the graph/reader")
    func openPageLeavesEvents() {
        let vm = WikiGraphViewModel()
        vm.showEventsPage = true

        vm.openPageLeavingEvents("wiki:topic:glossary-mcp")

        #expect(!vm.showEventsPage)                          // back on the graph surface
        #expect(vm.selectedPath == "wiki:topic:glossary-mcp") // shared selection plane
        // Reader presentation is platform-specific: a floating doc card on
        // macOS, the sheet on iOS.
        #if os(macOS)
        #expect(vm.docLayout.frontCard?.path == "wiki:topic:glossary-mcp")
        #else
        #expect(vm.showPageDetail)                            // reader presents it
        #endif
    }

    @Test("Switching wikis clears the events surface with the rest of the selection")
    func wikiSwitchClearsEventsPage() {
        let vm = WikiGraphViewModel()
        vm.prepareForLoad(wiki: "a")
        vm.showEventsPage = true

        vm.prepareForLoad(wiki: "b")

        #expect(!vm.showEventsPage)
    }
}

// MARK: - Conformance gating

@Suite("Wiki Event Timeline Gating")
@MainActor
struct WikiEventTimelineGatingTests {

    @Test("CentaurWikiClient provides the event timeline; GatewayClient does not")
    func onlyCentaurConforms() {
        let centaur: any WikiSource = CentaurWikiClient(
            baseURL: URL(string: "https://wiki.example.com")!, apiKey: "k"
        )
        #expect(centaur is (any WikiEventTimelineProviding))

        let hermes: any WikiSource = GatewayClient()
        #expect(!(hermes is (any WikiEventTimelineProviding)))
    }
}
