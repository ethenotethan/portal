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

    static let hermes = BackendCapabilities(
        supportsInteractivePrompts: true,
        supportsSubagentEvents: true,
        supportsWiki: true,
        supportsSkills: true,
        supportsAttachments: true,
        supportsModelSwitching: true
    )

    /// Centaur relays harness stdout; structured features stay dark until the
    /// sandbox harness emits typed events (SessionEventName::Other passthrough).
    static let centaur = BackendCapabilities(
        supportsInteractivePrompts: false,
        supportsSubagentEvents: false,
        supportsWiki: false,
        supportsSkills: false,
        supportsAttachments: false,
        supportsModelSwitching: false
    )
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
