import Foundation
import os

#if canImport(MLXLLM) && canImport(MLXLMCommon) && canImport(HuggingFace) && canImport(Tokenizers) && os(macOS)
@preconcurrency import MLXLLM
@preconcurrency import MLXLMCommon

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "LocalChatEngine")

/// MLX text generation for local discussions — the real engine behind
/// `LocalChatService`'s `LocalChatGenerating` seam.
///
/// An `actor`, and that is the whole design. Everywhere else in the app a
/// `ChatSession` is built per call and thrown away (see `SkillSummaryService`'s
/// long note): it isn't thread-safe, and its accumulating history is pure
/// downside when each call is independent. Here the accumulation IS the feature —
/// a discussion is multi-turn, and the KV cache is what makes turn four cheap and
/// contextual. So the session is retained, and the actor is what makes retaining
/// it safe: the session never crosses an isolation boundary (only `String`s and a
/// `Sendable` continuation do), and generations serialize instead of racing.
///
/// The actor's executor is a background thread, so inference never lands on the
/// main thread — the reason the other MLX call sites need an explicit
/// `Task.detached`.
internal actor MLXLocalChatEngine: LocalChatGenerating {
    /// The loaded weights (~0.6-5 GB of Metal buffers), keyed by which model they
    /// are so a Settings change reloads rather than silently answering with the
    /// old one.
    private var container: ModelContainer?
    private var loadedModel: LocalChatModel?

    /// The live conversation. Kept until the discussion ends (or its grounding
    /// changes), which is what gives turn-to-turn continuity.
    private var session: ChatSession?
    /// The instructions the live session was built with. A different discussion
    /// means different grounding, so the session must be rebuilt — otherwise the
    /// new anchor's questions are answered against the old anchor's text.
    private var sessionInstructions: String?

    /// Spoken replies are short by instruction; the cap is a backstop against a
    /// small model running away mid-sentence with the user waiting in silence.
    private static let parameters = GenerateParameters(maxTokens: 400, temperature: 0.7)

    internal init() {}

    internal func prepare(model: LocalChatModel) async throws {
        try await ensureContainer(for: model)
    }

    nonisolated internal func stream(
        instructions: String,
        prompt: String,
        model: LocalChatModel
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.generate(
                    instructions: instructions,
                    prompt: prompt,
                    model: model,
                    continuation: continuation
                )
            }
            // A cancelled consumer (the user ended the discussion, or barged in
            // over the reply) must stop the generation, not leave it burning GPU
            // into a stream nobody reads.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    internal func endSession() async {
        session = nil
        sessionInstructions = nil
    }

    // MARK: - Generation

    /// Actor-isolated so `session` never leaves this actor: the continuation is
    /// `Sendable` and carries the text out, while the non-`Sendable` session
    /// stays put.
    private func generate(
        instructions: String,
        prompt: String,
        model: LocalChatModel,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        do {
            let session = try await liveSession(instructions: instructions, model: model)
            for try await chunk in session.streamResponse(to: prompt) {
                if Task.isCancelled { break }
                continuation.yield(chunk)
            }
            continuation.finish()
        } catch {
            log.warning("Local discussion generation failed: \(error.localizedDescription)")
            continuation.finish(throwing: error)
        }
    }

    /// The session for this discussion, rebuilt when the grounding or the model
    /// changed and reused otherwise.
    private func liveSession(instructions: String, model: LocalChatModel) async throws -> ChatSession {
        try await ensureContainer(for: model)
        guard let container else { throw LocalChatError.unavailable }
        if let session, sessionInstructions == instructions { return session }
        let fresh = ChatSession(
            container,
            instructions: instructions,
            generateParameters: Self.parameters
        )
        session = fresh
        sessionInstructions = instructions
        return fresh
    }

    private func ensureContainer(for model: LocalChatModel) async throws {
        if container != nil, loadedModel == model { return }
        if loadedModel != model {
            // Switching models invalidates the conversation: its KV cache belongs
            // to the old weights.
            session = nil
            sessionInstructions = nil
        }
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: HFHubDownloader(),
            using: HFTokenizerLoaderWrapper(),
            configuration: Self.configuration(for: model)
        )
        container = loaded
        loadedModel = model
        log.info("Local discussion model loaded: \(model.label, privacy: .public)")
    }

    private static func configuration(for model: LocalChatModel) -> ModelConfiguration {
        switch model {
        case .gemma3_1b: return LLMRegistry.gemma3_1B_qat_4bit
        case .qwen3_1_7b: return LLMRegistry.qwen3_1_7b_4bit
        case .qwen3_4b: return LLMRegistry.qwen3_4b_4bit
        case .lfm2_8b_a1b: return LLMRegistry.lfm2_8b_a1b_3bit_mlx
        case .qwen3_8b: return LLMRegistry.qwen3_8b_4bit
        case .qwen3_30b_a3b: return LLMRegistry.qwen3MoE_30b_a3b_4bit
        }
    }
}

#endif
