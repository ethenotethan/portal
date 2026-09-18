import Foundation
import Testing
@testable import Portal

/// A stand-in for the MLX engine: replays scripted deltas, records what it was
/// asked, and never downloads anything.
private final class FakeChatEngine: LocalChatGenerating, @unchecked Sendable {
    /// Deltas for the next `stream` call, in order.
    var deltas: [String] = []
    /// Set to fail the generation partway through.
    var failsAfter: Int?
    var prepareError: Error?
    private(set) var preparedModels: [LocalChatModel] = []
    private(set) var prompts: [String] = []
    private(set) var instructions: [String] = []
    private(set) var endSessionCount = 0

    func prepare(model: LocalChatModel) async throws {
        preparedModels.append(model)
        if let prepareError { throw prepareError }
    }

    func stream(instructions: String, prompt: String, model: LocalChatModel) -> AsyncThrowingStream<String, Error> {
        self.instructions.append(instructions)
        prompts.append(prompt)
        let deltas = self.deltas
        let failsAfter = self.failsAfter
        return AsyncThrowingStream { continuation in
            for (index, delta) in deltas.enumerated() {
                if index == failsAfter {
                    continuation.finish(throwing: LocalChatError.loadFailed("boom"))
                    return
                }
                continuation.yield(delta)
            }
            if failsAfter == deltas.count {
                continuation.finish(throwing: LocalChatError.loadFailed("boom"))
                return
            }
            continuation.finish()
        }
    }

    func endSession() async { endSessionCount += 1 }
}

@Suite("Local chat service")
@MainActor
internal struct LocalChatServiceTests {

    /// A throwaway defaults domain per test, so opting in here never writes into
    /// the real app's settings.
    private func makeDefaults() -> UserDefaults {
        // swiftlint:disable:next force_unwrapping
        return UserDefaults(suiteName: "portal.tests.localchat.\(UUID().uuidString)")!
    }

    private func makeService(
        engine: (any LocalChatGenerating)?,
        enabled: Bool = true
    ) -> LocalChatService {
        let service = LocalChatService(engine: engine, defaults: makeDefaults())
        service.isEnabled = enabled
        return service
    }

    @Test("no engine means the feature reports itself unavailable")
    internal func unavailableWithoutEngine() async {
        let service = makeService(engine: nil)
        #expect(!service.isAvailable)
        #expect(!service.isEnabledAndAvailable)
        let result = await service.respond(instructions: "i", to: "q") { _ in }
        #expect(throws: LocalChatError.unavailable) { try result.get() }
    }

    @Test("an available engine still does nothing until the user opts in")
    internal func disabledUntilOptIn() async {
        let engine = FakeChatEngine()
        engine.deltas = ["hi"]
        let service = makeService(engine: engine, enabled: false)
        #expect(service.isAvailable)
        #expect(!service.isEnabledAndAvailable)

        let result = await service.respond(instructions: "i", to: "q") { _ in }
        #expect(throws: LocalChatError.unavailable) { try result.get() }
        #expect(engine.prompts.isEmpty)
    }

    @Test("preparing loads the selected model once")
    internal func prepareLoadsSelectedModel() async {
        let engine = FakeChatEngine()
        let service = makeService(engine: engine)
        service.model = .qwen3_4b

        service.prepare()
        await settle { !service.isPreparing }
        #expect(engine.preparedModels == [.qwen3_4b])
        #expect(service.lastError == nil)

        // Already loaded: asking again doesn't reload gigabytes of weights.
        service.prepare()
        await settle { !service.isPreparing }
        #expect(engine.preparedModels == [.qwen3_4b])
    }

    @Test("a failed load is reported and blocks generation")
    internal func failedLoadBlocksGeneration() async {
        let engine = FakeChatEngine()
        engine.prepareError = LocalChatError.loadFailed("no disk space")
        let service = makeService(engine: engine)

        service.prepare()
        await settle { !service.isPreparing }
        #expect(service.lastError == LocalChatError.loadFailed("no disk space").localizedDescription)

        let result = await service.respond(instructions: "i", to: "q") { _ in }
        #expect(throws: LocalChatError.self) { try result.get() }
    }

    @Test("deltas arrive in order and the cleaned reply is returned")
    internal func streamsInOrder() async {
        let engine = FakeChatEngine()
        engine.deltas = ["Keep ", "the ", "actor."]
        let service = makeService(engine: engine)

        var seen: [String] = []
        let result = await service.respond(instructions: "i", to: "why?") { seen.append($0) }
        #expect(seen == ["Keep ", "the ", "actor."])
        #expect((try? result.get()) == "Keep the actor.")
    }

    @Test("a reasoning block never reaches the caller")
    internal func suppressesThinkBlock() async {
        let engine = FakeChatEngine()
        engine.deltas = ["<thi", "nk>weighing it</think>", "Use the actor."]
        let service = makeService(engine: engine)

        var seen = ""
        let result = await service.respond(instructions: "i", to: "why?") { seen += $0 }
        #expect(seen == "Use the actor.")
        #expect((try? result.get()) == "Use the actor.")
    }

    @Test("a reply that is only reasoning counts as empty")
    internal func emptyReplyIsAnError() async {
        let engine = FakeChatEngine()
        engine.deltas = ["<think>", "hmm", "</think>", "  "]
        let service = makeService(engine: engine)

        let result = await service.respond(instructions: "i", to: "why?") { _ in }
        #expect(throws: LocalChatError.emptyResponse) { try result.get() }
    }

    @Test("a mid-stream failure keeps what was already said and records the error")
    internal func midStreamFailure() async {
        let engine = FakeChatEngine()
        engine.deltas = ["Half a th", "ought"]
        engine.failsAfter = 1
        let service = makeService(engine: engine)

        var seen = ""
        let result = await service.respond(instructions: "i", to: "why?") { seen += $0 }
        #expect(seen == "Half a th")
        #expect(throws: LocalChatError.self) { try result.get() }
        #expect(service.lastError != nil)

        // A failed generation must not latch the discussion shut — the next
        // question goes through.
        engine.deltas = ["Fine."]
        engine.failsAfter = nil
        let second = await service.respond(instructions: "i", to: "again?") { _ in }
        #expect((try? second.get()) == "Fine.")
        #expect(service.lastError == nil)
    }

    @Test("reasoning models are told to skip the monologue")
    internal func appendsNoThinkSuffix() async {
        let engine = FakeChatEngine()
        engine.deltas = ["ok"]
        let service = makeService(engine: engine)

        service.model = .qwen3_8b
        _ = await service.respond(instructions: "i", to: "why?") { _ in }
        #expect(engine.prompts.last == "why? /no_think")

        service.model = .gemma3_1b
        _ = await service.respond(instructions: "i", to: "why?") { _ in }
        #expect(engine.prompts.last == "why?")
    }

    @Test("switching models drops the session and the loaded state")
    internal func switchingModelResets() async {
        let engine = FakeChatEngine()
        let service = makeService(engine: engine)
        service.prepare()
        await settle { !service.isPreparing }
        #expect(service.isReady)

        service.model = .llama3_2_3b
        await settle { engine.endSessionCount == 1 }
        #expect(engine.endSessionCount == 1)
        #expect(!service.isReady)

        // …and the new weights are actually loaded rather than skipped.
        service.prepare()
        await settle { !service.isPreparing }
        #expect(engine.preparedModels == [.gemma3_1b, .llama3_2_3b])
    }

    @Test("ending the session forwards to the engine")
    internal func endSessionForwards() async {
        let engine = FakeChatEngine()
        let service = makeService(engine: engine)
        await service.endSession()
        #expect(engine.endSessionCount == 1)
    }

    @Test("the opt-ins persist")
    internal func settingsPersist() {
        let defaults = makeDefaults()
        let first = LocalChatService(engine: nil, defaults: defaults)
        first.isEnabled = true
        first.model = .qwen3_4b

        let second = LocalChatService(engine: nil, defaults: defaults)
        #expect(second.isEnabled)
        #expect(second.model == .qwen3_4b)
    }

    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
    }
}
