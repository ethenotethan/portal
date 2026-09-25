import Testing
import Foundation
@testable import Portal

@MainActor
@Suite("Architecture revisions model — history, selection, diff")
internal struct ArchitectureRevisionsModelTests {
    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    private func history() throws -> ArchitectureRevisionHistory {
        try ArchitectureRevisionHistory.decodeGatewayValue(try decode(ArchitectureRevisionsDocumentTests.historyJSON))
    }

    private func diff(from: String, to: String) throws -> ArchitectureRevisionDiff {
        try ArchitectureRevisionDiff.decodeGatewayValue(try decode("{\"service\": \"arch:portal\", \"from\": \"\(from)\", \"to\": \"\(to)\"}"))
    }

    private let genesis = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let latest = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    @Test("load selects the latest revision and diffs it against the previous one")
    internal func loadSelectsLatest() async throws {
        let reader = ArchitectureLogsRevisionsStub()
        reader.history = try history()
        reader.diffs["\(genesis)..\(latest)"] = try diff(from: genesis, to: latest)
        let model = ArchitectureRevisionsModel(service: "arch:portal", reader: reader)
        await model.load()
        #expect(model.timeline.map(\.shortRevision) == ["bbbbbbbbb", "aaaaaaaaa", "working-tree"])
        #expect(model.selectedRevision == latest)
        #expect(model.fromRevision == genesis)
        #expect(model.diff?.to == latest)
        #expect(reader.diffCalls.count == 1)
        #expect(model.errorMessage == nil)
        #expect(model.diffMessage == nil)
        #expect(!model.isLoadingHistory)
        #expect(!model.isLoadingDiff)
    }

    @Test("selecting a revision re-diffs against its previous; the earliest has nothing to compare")
    internal func selection() async throws {
        let reader = ArchitectureLogsRevisionsStub()
        reader.history = try history()
        reader.diffs["\(genesis)..\(latest)"] = try diff(from: genesis, to: latest)
        reader.diffs["working-tree..\(genesis)"] = try diff(from: "working-tree", to: genesis)
        let model = ArchitectureRevisionsModel(service: "arch:portal", reader: reader)
        await model.load()
        await model.select(revision: genesis)
        #expect(model.selectedRevision == genesis)
        #expect(model.fromRevision == "working-tree")
        #expect(model.diff?.from == "working-tree")
        await model.select(revision: "working-tree")
        #expect(model.diff == nil)
        #expect(model.diffMessage == "Earliest stored revision — nothing older to compare against")
        await model.select(revision: "working-tree")
        await model.select(revision: "missing")
        #expect(reader.diffCalls.count == 2, "re-selecting or selecting an unknown revision does not re-diff")
    }

    @Test("an explicit from-revision overrides the previous one; choosing the selected revision or nil clears it")
    internal func fromOverride() async throws {
        let reader = ArchitectureLogsRevisionsStub()
        reader.history = try history()
        reader.diffs["\(genesis)..\(latest)"] = try diff(from: genesis, to: latest)
        reader.diffs["working-tree..\(latest)"] = try diff(from: "working-tree", to: latest)
        let model = ArchitectureRevisionsModel(service: "arch:portal", reader: reader)
        await model.load()
        await model.setFrom(revision: "working-tree")
        #expect(model.fromOverride == "working-tree")
        #expect(model.diff?.from == "working-tree")
        await model.setFrom(revision: "working-tree")
        #expect(reader.diffCalls.count == 2, "setting the same override again does nothing")
        await model.setFrom(revision: "missing")
        #expect(model.fromOverride == "working-tree", "an unknown revision is ignored")
        await model.setFrom(revision: latest)
        #expect(model.fromOverride == nil, "the selected revision cannot be its own from")
        #expect(model.diff?.from == genesis)
        await model.setFrom(revision: "working-tree")
        await model.select(revision: "working-tree")
        #expect(model.fromOverride == nil, "selecting the override revision drops the override")
    }

    @Test("deltas compare a revision's summary with the previous one")
    internal func deltas() async throws {
        let reader = ArchitectureLogsRevisionsStub()
        reader.history = try history()
        reader.diffs["\(genesis)..\(latest)"] = try diff(from: genesis, to: latest)
        let model = ArchitectureRevisionsModel(service: "arch:portal", reader: reader)
        await model.load()
        let entry = try #require(model.selectedEntry)
        let delta = try #require(model.delta(for: entry))
        #expect(delta.nodes == 55)
        #expect(delta.edges == 48)
        #expect(delta.files == 21)
        #expect(delta.lines == 9950)
        #expect(delta.invariantsViolated == 1)
        #expect(!delta.isEmpty)
        let working = try #require(model.history.entry("working-tree"))
        #expect(model.delta(for: working) == nil, "the earliest revision has no previous")
        #expect(ArchitectureRevisionsModel.Delta.between(.empty, .empty).isEmpty)
    }

    @Test("history and diff errors surface the gateway's words")
    internal func errors() async throws {
        let reader = ArchitectureLogsRevisionsStub()
        reader.historyError = GatewayError.rpcError(JSONRPCError(code: 4030, message: "unknown architecture service arch:nope"))
        let model = ArchitectureRevisionsModel(service: "arch:nope", reader: reader)
        await model.load()
        #expect(model.errorMessage == "unknown architecture service arch:nope")
        #expect(model.timeline.isEmpty)
        reader.historyError = nil
        reader.history = try history()
        reader.diffError = GatewayError.rpcError(JSONRPCError(code: 4404, message: "no stored revision aaaa"))
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.diff == nil)
        #expect(model.diffMessage == "no stored revision aaaa")
    }
}
