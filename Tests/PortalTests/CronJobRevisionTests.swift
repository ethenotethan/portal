import Foundation
import Testing
@testable import Portal

// MARK: - Fixtures

/// Payloads shaped like the `cron.manage` `revisions` response: a populated
/// update, a create with before values absent, a deletion, and a pre-definition
/// baseline row that can only say the job existed.
private enum Fixtures {
    static let update: AnyCodable = .dictionary([
        "id": AnyCodable("cs-9"),
        "timestamp": AnyCodable("2026-09-27T10:15:00+00:00"),
        "action": AnyCodable("update"),
        "actor": AnyCodable("human"),
        "summary": AnyCodable("updated collect (model, prompt)"),
        "git_commit": AnyCodable("9f2c1ab"),
        "definition": .dictionary([
            "name": AnyCodable("collect"),
            "prompt": AnyCodable("collect, then summarise"),
            "model": AnyCodable("claude-y"),
            "schedule": AnyCodable("every 6h"),
            "skills": .array([AnyCodable("notes"), AnyCodable("search")]),
            "enabled": AnyCodable(true),
        ]),
        "changes": .array([
            .dictionary(["field": AnyCodable("prompt"), "before": AnyCodable("collect"), "after": AnyCodable("collect, then summarise")]),
            .dictionary(["field": AnyCodable("model"), "before": .null, "after": AnyCodable("claude-y")]),
            .dictionary(["field": AnyCodable("skills"), "before": .array([AnyCodable("notes")]), "after": .array([AnyCodable("notes"), AnyCodable("search")])]),
            .dictionary(["before": AnyCodable("no field name")]),
        ]),
        "definition_recorded": AnyCodable(true),
    ])

    static let created: AnyCodable = .dictionary([
        "id": AnyCodable("cs-3"),
        "timestamp": AnyCodable("2026-09-20T08:00:00.250+00:00"),
        "action": AnyCodable("create"),
        "actor": AnyCodable("agent"),
        "summary": AnyCodable("created collect"),
        "definition": .dictionary(["name": AnyCodable("collect"), "prompt": AnyCodable("collect"), "enabled": AnyCodable(true)]),
        "changes": .array([
            .dictionary(["field": AnyCodable("prompt"), "before": .null, "after": AnyCodable("collect")]),
            .dictionary(["field": AnyCodable("enabled"), "before": .null, "after": AnyCodable(true)]),
        ]),
    ])

    static let deleted: AnyCodable = .dictionary([
        "id": AnyCodable("cs-12"),
        "action": AnyCodable("delete"),
        "actor": AnyCodable("scheduler"),
        "definition": .null,
        "changes": .array([
            .dictionary(["field": AnyCodable("prompt"), "before": AnyCodable("collect, then summarise"), "after": .null]),
        ]),
    ])

    static let preDefinition: AnyCodable = .dictionary([
        "id": AnyCodable("cs-1"),
        "action": AnyCodable("baseline"),
        "definition_recorded": AnyCodable(false),
    ])

    static let page: AnyCodable = .dictionary([
        "success": AnyCodable(true),
        "job_id": AnyCodable("collect-1"),
        "job_name": AnyCodable("collect"),
        "revisions": .array([deleted, update, created, preDefinition, .dictionary(["action": AnyCodable("update")])]),
        "total": AnyCodable(4),
        "limit": AnyCodable(50),
        "offset": AnyCodable(0),
    ])
}

// MARK: - Decoding

@Suite("cron.manage revisions decoding")
internal struct CronJobRevisionDecodingTests {
    @Test("an update decodes its definition and every named field change")
    internal func decodesUpdate() throws {
        let revision = try #require(GatewayClient.cronJobRevision(from: Fixtures.update))
        #expect(revision.id == "cs-9")
        #expect(revision.action == "update")
        #expect(revision.actor == .human)
        #expect(revision.summary == "updated collect (model, prompt)")
        #expect(revision.gitCommit == "9f2c1ab")
        #expect(revision.definitionRecorded)
        #expect(revision.definition?["model"]?.stringValue == "claude-y")
        #expect(revision.definition?["skills"]?.arrayValue?.count == 2)
        // A change without a field name is dropped, never shown as "".
        #expect(revision.changes.count == 3)
        #expect(revision.changedFields == ["prompt", "model", "skills"])
        let model = try #require(revision.changes.first { $0.field == "model" })
        #expect(model.before == nil)
        #expect(model.beforeText == "—")
        #expect(model.afterText == "claude-y")
        let skills = try #require(revision.changes.first { $0.field == "skills" })
        #expect(skills.beforeText == "notes")
        #expect(skills.afterText == "notes, search")
        #expect(revision.date != nil)
    }

    @Test("a creation has no before values and a fractional timestamp still parses")
    internal func decodesCreate() throws {
        let revision = try #require(GatewayClient.cronJobRevision(from: Fixtures.created))
        #expect(revision.action == "create")
        #expect(revision.actor == .agent)
        #expect(revision.changes.allSatisfy { $0.before == nil })
        #expect(revision.changes.first { $0.field == "enabled" }?.afterText == "yes")
        #expect(revision.date != nil)
        // Absent `definition_recorded` means an old harness that always recorded.
        #expect(revision.definitionRecorded)
    }

    @Test("a deletion carries no definition and a pre-definition row says so")
    internal func decodesDeleteAndPreDefinition() throws {
        let deleted = try #require(GatewayClient.cronJobRevision(from: Fixtures.deleted))
        #expect(deleted.definition == nil)
        #expect(deleted.actor == .scheduler)
        #expect(deleted.changes.first?.afterText == "—")
        #expect(deleted.date == nil)
        let baseline = try #require(GatewayClient.cronJobRevision(from: Fixtures.preDefinition))
        #expect(!baseline.definitionRecorded)
        #expect(baseline.changes.isEmpty)
        #expect(baseline.actor == .unknown)
    }

    @Test("the page keeps order, counts the whole history, and drops an id-less row")
    internal func decodesPage() {
        let page = GatewayClient.cronJobRevisionsPage(from: Fixtures.page, jobID: "fallback", requestedLimit: 10, requestedOffset: 3)
        #expect(page.jobID == "collect-1")
        #expect(page.jobName == "collect")
        #expect(page.revisions.map(\.id) == ["cs-12", "cs-9", "cs-3", "cs-1"])
        #expect(page.total == 4)
        #expect(page.limit == 50)
        #expect(page.offset == 0)
    }

    @Test("a bare result falls back to what was requested")
    internal func decodesBareResult() {
        let page = GatewayClient.cronJobRevisionsPage(from: .dictionary([:]), jobID: "collect-1", requestedLimit: 20, requestedOffset: 5)
        #expect(page.jobID == "collect-1")
        #expect(page.jobName == nil)
        #expect(page.revisions.isEmpty)
        #expect(page.total == 0)
        #expect(page.limit == 20)
        #expect(page.offset == 5)
    }

    @Test("field values render for people")
    internal func rendersValues() {
        #expect(CronDefinitionChange.displayText(nil) == "—")
        #expect(CronDefinitionChange.displayText(AnyCodable("")) == "—")
        #expect(CronDefinitionChange.displayText(AnyCodable(false)) == "no")
        #expect(CronDefinitionChange.displayText(AnyCodable(3)) == "3")
        #expect(CronDefinitionChange.displayText(.array([])) == "—")
        #expect(CronDefinitionChange.displayText(.dictionary(["b": AnyCodable("2"), "a": AnyCodable("1")])) == "a: 1, b: 2")
    }
}
