import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "AgentBackend")

internal enum AgentBackendError: LocalizedError {
    case voiceNotSupported

    internal var errorDescription: String? {
        switch self {
        case .voiceNotSupported: "Voice features not supported by this backend"
        }
    }
}

/// A resumed session's transcript plus, when the gateway reports the turn is
/// still running, the in-flight turn — so the client can rebuild the live
/// streaming shell instead of dropping every delta that arrives for it.
///
/// A session spawned by an artifact intent (or started on another device) runs
/// its turn in the background; the resuming client never saw the `message.start`
/// that opens the streaming shell, so without this it has no message for the
/// running turn's deltas, thinking, tool and subagent events to attach to.
internal struct ResumedSession {
    internal var sessionID: String
    internal var messages: [[String: AnyCodable]]
    internal var inflight: InflightTurn?

    internal init(sessionID: String, messages: [[String: AnyCodable]], inflight: InflightTurn? = nil) {
        self.sessionID = sessionID
        self.messages = messages
        self.inflight = inflight
    }
}

/// The turn a resumed session is running right now, as the gateway sees it.
internal struct InflightTurn {
    /// Assistant text streamed BEFORE this client resumed. Seeds the shell so
    /// the visible answer doesn't restart from the next delta; the terminal
    /// `message.complete` replaces it with the authoritative full text.
    internal var assistantPartial: String
    /// The gateway still has a live turn open on this session.
    internal var isStreaming: Bool
}

/// The harness surface ChatViewModel actually consumes.
///
/// A protocol rather than `GatewayClient` directly so the chat pipeline can be
/// driven by a test spy: every member mirrors GatewayClient's existing
/// signature, so the production conformance is `extension GatewayClient:
/// AgentBackend {}` with no behavior change. Events arrive as `GatewayEvent`.
@MainActor
protocol AgentBackend: AnyObject {

    // MARK: Streams

    /// Typed events multiplexed across sessions: (event, sessionID?).
    var eventStream: PassthroughSubject<(GatewayEvent, String?), Never> { get }

    var connectionStatePublisher: AnyPublisher<GatewayClient.ConnectionState, Never> { get }
    var sessionInfoPublisher: AnyPublisher<SessionInfo?, Never> { get }

    /// Synchronous connection-state snapshot (guards in create/resume paths).
    var connectionState: GatewayClient.ConnectionState { get }

    /// Invoked after an automatic reconnect restores the transport.
    var onReconnected: (() async -> Void)? { get set }

    /// Bearer credential attachments/downloads may need (empty when unused).
    var apiKey: String { get }

    /// The backend's current runtime session ID, if any.
    var activeSessionID: String? { get }

    // MARK: Session Lifecycle

    func createSession(cols: Int) async throws -> String
    func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]])
    /// Like `resumeSession`, but also surfaces the in-flight turn when the
    /// harness reports one still running. Conformers without a live-turn
    /// resume inherit the default below, which reports no in-flight turn.
    func resumeSessionDetailed(key: String) async throws -> ResumedSession
    func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]]
    func interrupt(sessionID: String) async throws

    // MARK: Conversation

    func submitPrompt(sessionID: String, text: String) async throws
    /// Submit a turn, optionally through the tool-less "chat" path. Has a
    /// default (below) that ignores `chatMode`, so only the gateway client
    /// needs to implement it — test spies fall back to a normal turn.
    func submitPrompt(sessionID: String, text: String, chatMode: Bool) async throws
    func respondApproval(sessionID: String, choice: String, all: Bool) async throws
    func respondClarify(requestID: String, answer: String) async throws

    // MARK: Configuration

    func setConfig(key: String, value: String, sessionID: String?) async throws
    func setEphemeralPrompt(sessionID: String, prompt: String) async throws
    func setSessionSkills(sessionID: String, skillNames: [String]) async throws

    // MARK: Models

    /// Live model inventory; nil when the backend has no catalog RPC
    /// (callers fall back to `AgentModel.catalog`).
    func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog?
    /// Model switch that surfaces the backend's verdict (warnings,
    /// expensive-model confirmation gates). `provider` names the provider
    /// the pick came from (nil = backend's current provider).
    func switchModel(_ model: String, provider: String?, sessionID: String, confirm: Bool) async throws -> ModelSwitchOutcome

    // MARK: Attachments

    func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String?) async throws -> String
    func downloadFile(from url: URL, token: String?) async throws -> Data
    func attachImage(path: String, sessionID: String?) async throws

    /// Rewrite a server-provided media/asset URL that points at a loopback
    /// host (`localhost`/`127.0.0.1`) to THIS backend's reachable host, so
    /// delivered attachments open/download off-device. Non-loopback URLs and
    /// backends that serve reachable URLs already return the input unchanged.
    func resolvedMediaURL(_ raw: String) -> String

    // MARK: Voice

    /// Toggle voice mode on/off or check status.
    func voiceToggle(action: String) async throws -> [String: AnyCodable]?
    /// Start or stop VAD-bounded push-to-talk capture.
    func voiceRecord(action: String) async throws

    // MARK: Diagnostics

    func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String)
}

// MARK: - Defaults (GatewayClient overrides the ones it can answer)

extension AgentBackend {
    /// Default: resume with no in-flight turn. `GatewayClient` can resume INTO
    /// a running turn and overrides this to surface it.
    internal func resumeSessionDetailed(key: String) async throws -> ResumedSession {
        let result = try await resumeSession(key: key)
        return ResumedSession(sessionID: result.sessionID, messages: result.messages, inflight: nil)
    }

    /// Conformers without a tool-less chat path (a harness that doesn't
    /// advertise `prompt.chat_mode`) just run the normal turn — the flag is a
    /// hint, never a hard requirement.
    internal func submitPrompt(sessionID: String, text: String, chatMode: Bool) async throws {
        try await submitPrompt(sessionID: sessionID, text: text)
    }

    /// Conformers without an inventory RPC report no catalog; the picker falls
    /// back to the static list.
    func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog? { nil }

    /// Fallback switch path: plain config.set with no verdict surface.
    /// Provider qualification uses the gateway's "--provider" value syntax.
    func switchModel(_ model: String, provider: String?, sessionID: String, confirm: Bool) async throws -> ModelSwitchOutcome {
        let value = provider.map { "\(model) --provider \($0)" } ?? model
        try await setConfig(key: "model", value: value, sessionID: sessionID)
        return ModelSwitchOutcome(value: model, warning: "", confirmRequired: false, confirmMessage: "")
    }

    /// Backends whose media URLs are already reachable (no loopback rewrite)
    /// pass the URL through unchanged. GatewayClient overrides this.
    internal func resolvedMediaURL(_ raw: String) -> String { raw }

    // MARK: - Voice defaults (overridden by GatewayClient)

    internal func voiceToggle(action: String) async throws -> [String: AnyCodable]? {
        log.info("voiceToggle(\(action)) — not supported by this backend")
        throw AgentBackendError.voiceNotSupported
    }

    internal func voiceRecord(action: String) async throws {
        log.info("voiceRecord(\(action)) — not supported by this backend")
        throw AgentBackendError.voiceNotSupported
    }
}

// MARK: - GatewayClient Conformance

extension GatewayClient: AgentBackend {

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var sessionInfoPublisher: AnyPublisher<SessionInfo?, Never> {
        $sessionInfo.eraseToAnyPublisher()
    }
}
