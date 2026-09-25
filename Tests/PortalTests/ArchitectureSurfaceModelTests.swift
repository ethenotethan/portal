import Testing
import Foundation
import Combine
@testable import Portal

@MainActor
private final class StubArchitectureReader: ArchitectureReading {
    var document: ArchitectureModelDocument?
    var describeError: Error?
    var checkResult: ArchitectureCheckResult?
    var checkError: Error?
    var describeCalls: [(service: String, revision: String?)] = []
    var checkCalls = 0
    let events = PassthroughSubject<GatewayEvent, Never>()

    var architectureEvents: AnyPublisher<GatewayEvent, Never> { events.eraseToAnyPublisher() }

    func architectureLogs(service: String, sink: String?, lines: Int, cursor: String?) async throws -> ArchitectureLogTail {
        throw GatewayError.invalidResponse("logs not stubbed")
    }

    func architectureLogsFollow(service: String, sink: String?, enabled: Bool) async throws -> ArchitectureLogFollowState {
        throw GatewayError.invalidResponse("follow not stubbed")
    }

    func architectureHistory(service: String, limit: Int?) async throws -> ArchitectureRevisionHistory {
        throw GatewayError.invalidResponse("history not stubbed")
    }

    func architectureDiff(service: String, from: String?, to: String?) async throws -> ArchitectureRevisionDiff {
        throw GatewayError.invalidResponse("diff not stubbed")
    }

    func architectureDescribe(service: String, revision: String?) async throws -> ArchitectureModelDocument {
        describeCalls.append((service, revision))
        if let describeError { throw describeError }
        guard let document else { throw GatewayError.invalidResponse("no document") }
        return document
    }

    func architectureCheck(service: String) async throws -> ArchitectureCheckResult {
        checkCalls += 1
        if let checkError { throw checkError }
        guard let checkResult else { throw GatewayError.invalidResponse("no check") }
        return checkResult
    }
}

@MainActor
@Suite("Architecture surface model")
internal struct ArchitectureSurfaceModelTests {
    private func document(local: Bool = true, checkConfigured: Bool = true, repository: String? = nil) -> ArchitectureModelDocument {
        ArchitectureModelDocument(
            service: ArchitectureServiceRef(
                id: "arch:portal", label: "Portal", description: "d", source: local ? "local" : "github",
                root: local ? "/tmp/portal" : nil, repository: repository, ref: repository == nil ? nil : "main",
                modelPath: "architecture/model/model.json", checkConfigured: checkConfigured
            ),
            revision: "abc", source: local ? "local" : "github", storedAt: nil,
            summary: .empty, check: nil, contract: .unknown, model: .dictionary(["schema_version": .string("1.0.0")]),
            modelJSON: "{\"schema_version\":\"1.0.0\"}"
        )
    }

    @Test("loading fetches the document for the native renderers")
    internal func loadsAndBuildsPage() async {
        let reader = StubArchitectureReader()
        reader.document = document(repository: "ethenotethan/portal")
        let model = ArchitectureSurfaceModel(service: "arch:portal", revision: "abc", reader: reader)
        #expect(model.phase == .idle)
        #expect(!model.canRunCheck)
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.document?.service.id == "arch:portal")
        #expect(model.canRunCheck)
        #expect(reader.describeCalls.count == 1)
        #expect(reader.describeCalls.first?.revision == "abc")
    }

    @Test("a gateway error surfaces its own message; the surface can retry")
    internal func failsWithGatewayMessage() async {
        let reader = StubArchitectureReader()
        reader.describeError = GatewayError.rpcError(JSONRPCError(code: 4032, message: "model not found at /x; run the service's compiler first"))
        let model = ArchitectureSurfaceModel(service: "arch:portal", reader: reader)
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.errorMessage == "model not found at /x; run the service's compiler first")
        reader.describeError = nil
        reader.document = document()
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.errorMessage == nil)
    }

    @Test("load(revision:) fetches a stored snapshot and flags the surface as viewing an older revision; nil returns to latest")
    internal func revisionSwitching() async {
        let reader = StubArchitectureReader()
        reader.document = document()
        let model = ArchitectureSurfaceModel(service: "arch:portal", reader: reader)
        await model.load()
        #expect(!model.isViewingOlderRevision)
        await model.load(revision: "older")
        #expect(model.revision == "older")
        #expect(model.isViewingOlderRevision)
        #expect(reader.describeCalls.last?.revision == "older")
        await model.load(revision: nil)
        #expect(model.revision == nil)
        #expect(!model.isViewingOlderRevision)
        #expect(reader.describeCalls.last?.revision == nil)
        #expect(reader.describeCalls.count == 3)
    }

    @Test("a non-conforming model refused by the gateway (4033) fails with the gateway's words")
    internal func nonConformingRefusal() async {
        let reader = StubArchitectureReader()
        reader.describeError = GatewayError.rpcError(JSONRPCError(
            code: 4033,
            message: "model at /x does not conform to hermes.architecture v1.0: extraction.entities: construction 'store:a' has no provenance"
        ))
        let model = ArchitectureSurfaceModel(service: "arch:x", reader: reader)
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.errorMessage?.contains("does not conform to hermes.architecture v1.0") == true)
        #expect(model.errorMessage?.contains("has no provenance") == true)
    }

    @Test("only a local service with a declared check can be checked from here")
    internal func checkAvailability() async {
        let reader = StubArchitectureReader()
        reader.document = document(local: false, checkConfigured: false, repository: "o/r")
        let remote = ArchitectureSurfaceModel(service: "arch:r", reader: reader)
        await remote.load()
        #expect(!remote.canRunCheck)
        reader.document = document(local: true, checkConfigured: false)
        let unconfigured = ArchitectureSurfaceModel(service: "arch:u", reader: reader)
        await unconfigured.load()
        #expect(!unconfigured.canRunCheck)
    }

    @Test("running a check updates the document and summarises the outcome")
    internal func runsCheck() async {
        let reader = StubArchitectureReader()
        reader.document = document()
        reader.checkResult = ArchitectureCheckResult(
            status: "failed", exitCode: 2, output: "drift", reason: "", checkedAt: "t", revision: "abc", durationSeconds: 12.3
        )
        let model = ArchitectureSurfaceModel(service: "arch:portal", reader: reader)
        await model.load()
        await model.runCheck()
        #expect(reader.checkCalls == 1)
        #expect(model.document?.check?.status == "failed")
        #expect(model.checkMessage == "Check failed (exit 2) in 12s")
        #expect(!model.isChecking)
        reader.checkError = GatewayError.rpcError(JSONRPCError(code: 5042, message: "boom"))
        await model.runCheck()
        #expect(model.checkMessage == "boom")
        #expect(model.document?.check?.status == "failed", "a failed call leaves the last result in place")
    }

    @Test("check summaries read as one line")
    internal func checkSummaries() {
        let passed = ArchitectureCheckResult(status: "passed", exitCode: 0, output: "", reason: "", checkedAt: "", revision: "", durationSeconds: 1.5)
        #expect(ArchitectureSurfaceModel.checkSummary(passed) == "Check passed in 1.5s")
        let failed = ArchitectureCheckResult(status: "failed", exitCode: nil, output: "", reason: "", checkedAt: "", revision: "", durationSeconds: 61)
        #expect(ArchitectureSurfaceModel.checkSummary(failed) == "Check failed in 61s")
        let unavailable = ArchitectureCheckResult(status: "unavailable", exitCode: nil, output: "", reason: "no check command", checkedAt: "", revision: "", durationSeconds: 0)
        #expect(ArchitectureSurfaceModel.checkSummary(unavailable) == "Check unavailable: no check command")
        let bare = ArchitectureCheckResult(status: "unavailable", exitCode: nil, output: "", reason: "", checkedAt: "", revision: "", durationSeconds: 0)
        #expect(ArchitectureSurfaceModel.checkSummary(bare) == "Check unavailable")
        #expect(ArchitectureSurfaceModel.friendly(GatewayError.notConnected) == GatewayError.notConnected.localizedDescription)
    }
}
