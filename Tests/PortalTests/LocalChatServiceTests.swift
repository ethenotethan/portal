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

    /// A fixed machine, so the default model (and therefore what gets loaded)
    /// doesn't depend on whichever Mac the suite runs on.
    private static let mac16GB = HardwareProfile(memoryGB: 16, chip: "Apple M4")

    /// A machine with an empty model cache. Every test that isn't *about* the
    /// cache uses this: pointed at the real hub the default model would depend on
    /// whatever the developer has downloaded.
    private static let emptyCache = LocalModelCacheScanner(root: nil)

    private func makeService(
        engine: (any LocalChatGenerating)?,
        enabled: Bool = true,
        hardware: HardwareProfile = Self.mac16GB,
        scanner: LocalModelCacheScanner = LocalChatServiceTests.emptyCache
    ) -> LocalChatService {
        let service = LocalChatService(
            engine: engine, defaults: makeDefaults(), hardware: hardware, scanner: scanner
        )
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

    @Test("opting in starts the download there and then, not at the first question")
    internal func optingInPreloads() async {
        let engine = FakeChatEngine()
        let service = makeService(engine: engine, enabled: false)
        #expect(engine.preparedModels.isEmpty)

        service.isEnabled = true
        await settle { !service.isPreparing }
        // Waiting for gigabytes of weights mid-conversation is the thing this
        // avoids: the load happens while the user is still in Settings.
        #expect(engine.preparedModels == [.qwen3_4b])
        #expect(service.isReady)
        #expect(service.lastError == nil)

        // Already loaded: asking again doesn't reload it.
        service.prepare()
        await settle { !service.isPreparing }
        #expect(engine.preparedModels == [.qwen3_4b])
    }

    @Test("the default model is the one that suits the machine")
    internal func defaultModelFollowsHardware() {
        let air = makeService(engine: nil, hardware: HardwareProfile(memoryGB: 8, chip: "Apple M2"))
        #expect(air.model == .qwen3_1_7b)
        #expect(air.recommendedModel == .qwen3_1_7b)

        let studio = makeService(engine: nil, hardware: HardwareProfile(memoryGB: 128, chip: "Apple M3 Ultra"))
        #expect(studio.model == .qwen3_30b_a3b)
    }

    @Test("an Intel Mac reports the feature unavailable rather than failing at load")
    internal func intelIsUnavailable() {
        let service = makeService(
            engine: FakeChatEngine(),
            hardware: HardwareProfile(memoryGB: 32, chip: "Intel Core i9", isAppleSilicon: false)
        )
        // The weights would download and then fail on a Metal-less GPU.
        #expect(!service.isAvailable)
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

    @Test("switching models drops the session and loads the new weights")
    internal func switchingModelResets() async {
        let engine = FakeChatEngine()
        let service = makeService(engine: engine)
        await settle { service.isReady }

        service.model = .qwen3_8b
        await settle { engine.endSessionCount == 1 }
        #expect(engine.endSessionCount == 1)

        // The new weights are actually loaded rather than skipped — an in-flight
        // load for the old model used to swallow the switch.
        await settle { service.isReady }
        #expect(engine.preparedModels == [.qwen3_4b, .qwen3_8b])
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
        let first = LocalChatService(
            engine: nil, defaults: defaults, hardware: Self.mac16GB, scanner: Self.emptyCache
        )
        first.isEnabled = true
        // Deliberately not this machine's recommendation: an explicit pick has to
        // survive, not be re-derived from the hardware on every launch.
        first.model = .qwen3_8b

        let second = LocalChatService(
            engine: nil, defaults: defaults, hardware: Self.mac16GB, scanner: Self.emptyCache
        )
        #expect(second.isEnabled)
        #expect(second.model == .qwen3_8b)
    }

    @Test("first run uses weights that are already on the machine")
    internal func firstRunUsesDownloadedWeights() throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        try cache.install(.gemma3_1b)

        let studio = makeService(
            engine: FakeChatEngine(),
            enabled: false,
            hardware: HardwareProfile(memoryGB: 64, chip: "Apple M4 Max"),
            scanner: cache.scanner
        )
        // Opting in starts the download, so the default must not be a 17 GB fetch
        // when something usable is already here — the recommendation is still
        // offered in Settings.
        #expect(studio.model == .gemma3_1b)
        #expect(studio.recommendedModel == .qwen3_30b_a3b)
        #expect(studio.inventory.isDownloaded(.gemma3_1b))
        #expect(!studio.inventory.isDownloaded(.qwen3_30b_a3b))
    }

    @Test("an explicit pick isn't overridden by what happens to be downloaded")
    internal func savedModelBeatsDownloadedWeights() throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        try cache.install(.gemma3_1b)
        let defaults = makeDefaults()
        defaults.set(LocalChatModel.qwen3_8b.rawValue, forKey: LocalChatService.modelKey)

        let service = LocalChatService(
            engine: nil,
            defaults: defaults,
            hardware: HardwareProfile(memoryGB: 64, chip: "Apple M4 Max"),
            scanner: cache.scanner
        )
        #expect(service.model == .qwen3_8b)
    }

    @Test("what's on disk is re-read rather than assumed")
    internal func inventoryRefreshes() async throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        let service = makeService(engine: FakeChatEngine(), enabled: false, scanner: cache.scanner)
        #expect(!service.inventory.isDownloaded(.gemma3_1b))

        // Weights can land while the app is running — this model download, or the
        // skill summarizer's, or huggingface-cli in a terminal.
        try cache.install(.gemma3_1b)
        service.refreshInventory()
        await settle { service.inventory.isDownloaded(.gemma3_1b) }
        #expect(service.inventory.isDownloaded(.gemma3_1b))
        #expect(service.inventory.summary?.contains("Gemma 3 1B") == true)
    }

    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
    }
}
