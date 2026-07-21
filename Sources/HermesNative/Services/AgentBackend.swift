import Foundation
import Combine

// MARK: - Agent Backend

/// The backend surface ChatViewModel actually consumes, extracted so a second
/// agent platform (Centaur — REST + SSE) can sit behind the same chat UI as
/// the Hermes gateway (WebSocket JSON-RPC).
///
/// Design notes:
/// - Events arrive as the existing `GatewayEvent` enum regardless of backend;
///   non-Hermes backends adapt their wire events into it (see
///   `CentaurEventAdapter`). The per-session state machinery in ChatViewModel
///   is backend-agnostic once events are normalized.
/// - `capabilities` gates UI: Centaur has no wiki/skills/cron/voice, and its
///   sessions can't answer approval/clarify prompts (the harness runs
///   non-interactively in a sandbox).
/// - Members deliberately mirror GatewayClient's existing signatures so the
///   conformance is `extension GatewayClient: AgentBackend {}` with no
///   behavior change.
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

    // MARK: Capabilities

    var capabilities: BackendCapabilities { get }

    // MARK: Session Lifecycle

    func createSession(cols: Int) async throws -> String
    func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]])
    func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]]
    func interrupt(sessionID: String) async throws

    // MARK: Conversation

    func submitPrompt(sessionID: String, text: String) async throws
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
    /// expensive-model confirmation gates).
    func switchModel(_ model: String, sessionID: String, confirm: Bool) async throws -> ModelSwitchOutcome

    // MARK: Attachments

    func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String?) async throws -> String
    func downloadFile(from url: URL, token: String?) async throws -> Data
    func attachImage(path: String, sessionID: String?) async throws

    // MARK: Diagnostics

    func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String)
}

// MARK: - Backend Capabilities

/// Feature flags a backend advertises so the UI can hide what can't work.
struct BackendCapabilities: Sendable {
    /// Blocking approval/clarify prompts can be answered (Hermes only).
    var supportsInteractivePrompts: Bool
    /// subagent.* events flow, powering spawn trees and agent graph lanes.
    var supportsSubagentEvents: Bool
    /// wiki.* RPCs exist.
    var supportsWiki: Bool
    /// Skills catalog / attach RPCs exist.
    var supportsSkills: Bool
    /// File upload/attach RPCs exist.
    var supportsAttachments: Bool
    /// Model switching via config.set.
    var supportsModelSwitching: Bool
    /// Ephemeral system-prompt injection (config-driven response styles).
    var supportsResponseStyles: Bool
    /// Home-gateway service surface beyond chat: cron, activity inbox,
    /// feed, learning. These are Hermes gateway RPCs, not chat features —
    /// harness backends never grow them.
    var supportsGatewayServices: Bool
    /// Per-session introspection RPCs beyond plain history: session.timeline
    /// (playback), session.usage, session.peek, prompt breakdown. Gates the
    /// Explorer's Timeline/Usage tabs — backends without these RPCs show
    /// their raw event log instead (see `RawEventLogProviding`).
    var supportsSessionIntrospection: Bool
    /// Centaur workflow runtime introspection (/api/workflows/*): schedules
    /// + run history. The Centaur analogue of Hermes cron.
    var supportsWorkflows: Bool
    /// Fixed identity the chat chrome must present for this harness.
    /// nil = presentation is persona-driven (PersonaManager / gateway
    /// PERSONA.md sync). Non-nil harnesses are a different agent platform,
    /// not a Hermes persona — the user is not "messaging Hermes".
    var harnessPersona: Persona?

    static let hermes = BackendCapabilities(
        supportsInteractivePrompts: true,
        supportsSubagentEvents: true,
        supportsWiki: true,
        supportsSkills: true,
        supportsAttachments: true,
        supportsModelSwitching: true,
        supportsResponseStyles: true,
        supportsGatewayServices: true,
        supportsSessionIntrospection: true,
        supportsWorkflows: false,
        harnessPersona: nil
    )

    /// Centaur relays harness stdout; structured features stay dark until the
    /// sandbox harness emits typed events (SessionEventName::Other passthrough).
    static let centaur = BackendCapabilities(
        supportsInteractivePrompts: false,
        supportsSubagentEvents: false,
        // Wiki reads route through Darkbloom's public wiki-api REST
        // endpoints (CentaurWikiClient), not the hermes wiki.* RPCs.
        supportsWiki: true,
        supportsSkills: false,
        supportsAttachments: false,
        supportsModelSwitching: false,
        supportsResponseStyles: false,
        supportsGatewayServices: false,
        supportsSessionIntrospection: false,
        supportsWorkflows: true,
        harnessPersona: .centaurPersona
    )
}

// MARK: - Defaults for backends without a model catalog

extension AgentBackend {
    /// Backends without an inventory RPC (Centaur) report no catalog; the
    /// picker falls back to the static list (or hides, per capabilities).
    func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog? { nil }

    /// Fallback switch path: plain config.set with no verdict surface.
    func switchModel(_ model: String, sessionID: String, confirm: Bool) async throws -> ModelSwitchOutcome {
        try await setConfig(key: "model", value: model, sessionID: sessionID)
        return ModelSwitchOutcome(value: model, warning: "", confirmRequired: false, confirmMessage: "")
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

    var capabilities: BackendCapabilities { .hermes }
}
