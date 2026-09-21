import Testing
import Foundation
@testable import Portal

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

// MARK: - Out-of-window counting

/// `outOfWindowCount(domain:)` counts dated events whose time falls outside the
/// requested window — it turns an empty plot into a legible "these sit outside
/// this window" message. Undated events (no plotted x) are neither in nor out.
@Suite("Wiki Event Timeline Window Counting")
internal struct WikiEventTimelineWindowCountingTests {

    /// Minimal event: only the source key and occurred-at time matter here.
    private func event(_ key: String, occurredAt: String?) -> WikiTimelineEvent {
        WikiTimelineEvent(
            sourceKey: key,
            kindRaw: "github_pr",
            label: key,
            url: "",
            occurredAt: occurredAt.flatMap { WikiTimelineDecoding.parseDate($0) },
            ingestedAt: nil,
            eventTimeEstimated: false,
            actorSlackID: nil,
            actorName: nil,
            directiveBody: nil,
            directiveExcerpt: nil,
            targetPages: nil,
            directiveStatus: nil,
            resultingRevisionIDs: nil
        )
    }

    @Test("only dated events outside the domain are counted; undated and in-window are not")
    internal func countsOutOfWindow() throws {
        let timeline = WikiEventTimeline(
            since: nil,
            until: nil,
            eventCount: 4,
            eventsByKind: [:],
            events: [
                event("in-window", occurredAt: "2026-07-15T00:00:00Z"),
                event("before", occurredAt: "2026-06-01T00:00:00Z"),
                event("after", occurredAt: "2026-08-01T00:00:00Z"),
                event("undated", occurredAt: nil),
            ]
        )
        let start = try #require(WikiTimelineDecoding.parseDate("2026-07-01T00:00:00Z"))
        let end = try #require(WikiTimelineDecoding.parseDate("2026-07-31T00:00:00Z"))
        let domain = start...end

        #expect(timeline.outOfWindowCount(domain: domain) == 2)
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
        // Reader presentation is uniform now: the docked panel on macOS and the
        // sheet on iOS both key off showPageDetail + the shared selectedPath.
        #expect(vm.showPageDetail)
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

    @Test("the harness gateway provides the event log")
    internal func gatewayConformsToEventLog() {
        let hermes: any WikiSource = GatewayClient()
        #expect(hermes is (any WikiEventLogSource))
    }
}
