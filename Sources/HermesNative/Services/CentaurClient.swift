import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "CentaurClient")

// MARK: - Centaur Client

/// AgentBackend implementation for a Centaur control plane
/// (github.com/paradigmxyz/centaur — services/api-rs).
///
/// Protocol shape (REST + SSE, not WebSocket JSON-RPC):
/// - POST /api/session/{thread_key}            create or reuse a session
/// - POST /api/session/{thread_key}/messages   append the user turn
/// - POST /api/session/{thread_key}/execute    start the harness
/// - POST /api/session/{thread_key}/interrupt  stop the current execution
/// - GET  /api/session/{thread_key}/events     SSE stream, replayable via
///                                             ?after_event_id=N
///
/// Wire events are sparse (session.output.line + execution lifecycle);
/// `CentaurEventAdapter` normalizes them into `GatewayEvent` so ChatViewModel
/// renders a Centaur session with zero changes. Replay-from-cursor makes
/// reconnects lossless: we persist the last seen SSE event id per thread and
/// resume from it.
@MainActor
final class CentaurClient: ObservableObject {

    @Published var connectionState: GatewayClient.ConnectionState = .disconnected
    @Published var sessionInfo: SessionInfo?

    let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()

    private(set) var activeSessionID: String?

    /// e.g. https://centaur.internal.example.com
    private let baseURL: URL
    /// Sent as `Authorization: Bearer …` (console JWT) or x-centaur-api-key.
    let apiKey: String

    /// Reconnect hook required by AgentBackend; SSE resume is cursor-based so
    /// there is no separate resubscribe step, but callers may still want the
    /// notification.
    var onReconnected: (() async -> Void)?
    private let harnessType: String

    private var sseTask: Task<Void, Never>?
    /// Last SSE event id per thread_key, for ?after_event_id replay.
    private var lastEventID: [String: Int64] = [:]
    private var adapter = CentaurEventAdapter()

    private let session: URLSession

    init(baseURL: URL, apiKey: String, harnessType: String = "claude_code") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.harnessType = harnessType

        let config = URLSessionConfiguration.default
        // SSE is a long poll; never let the request idle-timeout mid-stream.
        config.timeoutIntervalForRequest = 3600
        config.timeoutIntervalForResource = .infinity
        self.session = URLSession(configuration: config)
    }

    deinit {
        sseTask?.cancel()
    }

    private static func makeSessionInfo(harness: String) -> SessionInfo {
        SessionInfo(
            model: harness,
            reasoningEffort: "",
            fast: false,
            tools: [:],
            skills: [:],
            cwd: "",
            version: "centaur",
            usage: nil,
            mcpServers: nil
        )
    }

    // MARK: - Requests

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(apiKey, forHTTPHeaderField: "x-centaur-api-key")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw GatewayError.invalidResponse("non-HTTP response from Centaur")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw GatewayError.rpcError(JSONRPCError(
                code: http.statusCode,
                message: "Centaur \(method) \(path): \(message)"
            ))
        }
        return data
    }

    private func json(_ data: Data) throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - Session Lifecycle

    /// Create (or reuse) a Centaur session. The thread_key doubles as the
    /// session ID everywhere in the app.
    func createSession(cols: Int = 120) async throws -> String {
        connectionState = .connecting
        let threadKey = "native-\(UUID().uuidString.prefix(12).lowercased())"
        do {
            _ = try await request("POST", "api/session/\(threadKey)", body: [
                "harness_type": harnessType,
            ])
        } catch {
            connectionState = .error(error.localizedDescription)
            throw error
        }
        activeSessionID = threadKey
        connectionState = .connected
        sessionInfo = Self.makeSessionInfo(harness: harnessType)
        startEventStream(threadKey: threadKey)
        return threadKey
    }

    /// Reattach to an existing thread. Centaur has no transcript-fetch REST
    /// endpoint; history replays through the SSE cursor instead, so this
    /// returns no messages and resumes the stream from event 0 when we have
    /// no stored cursor (full replay) or from the stored cursor otherwise.
    func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        connectionState = .connecting
        do {
            _ = try await request("POST", "api/session/\(key)", body: [
                "harness_type": harnessType,
            ])
        } catch {
            connectionState = .error(error.localizedDescription)
            throw error
        }
        activeSessionID = key
        connectionState = .connected
        sessionInfo = Self.makeSessionInfo(harness: harnessType)
        startEventStream(threadKey: key)
        return (sessionID: key, messages: [])
    }

    func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] {
        // No transcript REST endpoint; SSE replay (after_event_id=0) is the
        // history mechanism. ChatViewModel treats an empty array as "nothing
        // extra to merge".
        []
    }

    func interrupt(sessionID: String) async throws {
        _ = try await request("POST", "api/session/\(sessionID)/interrupt", body: [
            "reason": "user interrupt from HermesNative",
        ])
    }

    // MARK: - Conversation

    func submitPrompt(sessionID: String, text: String) async throws {
        _ = try await request("POST", "api/session/\(sessionID)/messages", body: [
            "messages": [["role": "user", "content": text]],
        ])
        let data = try await request("POST", "api/session/\(sessionID)/execute", body: [
            "idempotency_key": UUID().uuidString,
            "input_lines": [text],
        ])
        let result = try json(data)
        adapter.beginExecution(id: result["execution_id"] as? String)
        // Centaur emits execution_started on the SSE stream; message.start is
        // synthesized there so remote-initiated turns (Slack) also render.
    }

    func respondApproval(sessionID: String, choice: String, all: Bool = false) async throws {
        throw GatewayError.invalidResponse("Centaur sessions run non-interactively — approvals are handled by sandbox policy")
    }

    func respondClarify(requestID: String, answer: String) async throws {
        throw GatewayError.invalidResponse("Centaur sessions run non-interactively")
    }

    // MARK: - Configuration (not supported by the Centaur API)

    func setConfig(key: String, value: String, sessionID: String? = nil) async throws {
        throw GatewayError.invalidResponse("Centaur has no config.set — harness is fixed per session")
    }

    func setEphemeralPrompt(sessionID: String, prompt: String) async throws {
        // Personas are chosen at session create; silently ignore.
    }

    func setSessionSkills(sessionID: String, skillNames: [String]) async throws {
        // Skills live in the sandbox overlay, not the client protocol.
    }

    // MARK: - Attachments (not supported)

    func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String? = nil) async throws -> String {
        throw GatewayError.invalidResponse("Centaur backend does not support file upload")
    }

    func downloadFile(from url: URL, token: String? = nil) async throws -> Data {
        let (data, _) = try await session.data(from: url)
        return data
    }

    func attachImage(path: String, sessionID: String? = nil) async throws {
        throw GatewayError.invalidResponse("Centaur backend does not support image attach")
    }

    // MARK: - Diagnostics

    func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {
        log.debug("dropped \(event.debugName) (\(reason))")
    }

    // MARK: - SSE

    private func startEventStream(threadKey: String) {
        sseTask?.cancel()
        sseTask = Task { [weak self] in
            await self?.runEventStream(threadKey: threadKey)
        }
    }

    /// Long-lived SSE loop with cursor replay. Reconnects with backoff until
    /// cancelled; every reconnect resumes from the last seen event id, so no
    /// output is lost across network blips or app backgrounding.
    private func runEventStream(threadKey: String) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let after = lastEventID[threadKey] ?? 0
                var req = URLRequest(url: baseURL.appendingPathComponent("api/session/\(threadKey)/events")
                    .appending(queryItems: [URLQueryItem(name: "after_event_id", value: String(after))]))
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue(apiKey, forHTTPHeaderField: "x-centaur-api-key")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                let (bytes, response) = try await session.bytes(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw GatewayError.invalidResponse("SSE connect failed")
                }
                if attempt > 0 { await onReconnected?() }
                attempt = 0
                connectionState = .connected

                var parser = SSEParser()
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    guard let frame = parser.consume(line: line) else { continue }
                    if let id = frame.id, let numeric = Int64(id) {
                        lastEventID[threadKey] = numeric
                    }
                    for event in adapter.adapt(frame: frame) {
                        eventStream.send((event, threadKey))
                    }
                }
            } catch {
                if Task.isCancelled { return }
                attempt += 1
                connectionState = .reconnecting(attempt: attempt)
                log.warning("SSE stream dropped (attempt \(attempt)): \(error.localizedDescription)")
                let delay = min(pow(2.0, Double(attempt)), 30.0)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }
}

// MARK: - AgentBackend Conformance

extension CentaurClient: AgentBackend {

    var connectionStatePublisher: AnyPublisher<GatewayClient.ConnectionState, Never> {
        $connectionState.eraseToAnyPublisher()
    }

    var sessionInfoPublisher: AnyPublisher<SessionInfo?, Never> {
        $sessionInfo.eraseToAnyPublisher()
    }

    var capabilities: BackendCapabilities { .centaur }
}

// MARK: - SSE Parser

/// Minimal server-sent-events framer: accumulates `id:`/`event:`/`data:`
/// fields until the blank-line terminator, then emits one frame.
/// Multi-line data joins with \n per the SSE spec.
struct SSEParser {
    struct Frame {
        var id: String?
        var event: String = "message"
        var data: String = ""
    }

    private var current = Frame()

    mutating func consume(line: String) -> Frame? {
        if line.isEmpty {
            guard !current.data.isEmpty || current.id != nil else { return nil }
            let frame = current
            current = Frame()
            return frame
        }
        if line.hasPrefix(":") { return nil }  // comment / keepalive

        let (field, value): (Substring, Substring)
        if let colon = line.firstIndex(of: ":") {
            field = line[line.startIndex..<colon]
            var v = line[line.index(after: colon)...]
            if v.hasPrefix(" ") { v = v.dropFirst() }
            value = v
        } else {
            field = line[...]
            value = ""
        }

        switch field {
        case "id": current.id = String(value)
        case "event": current.event = String(value)
        case "data": current.data += (current.data.isEmpty ? "" : "\n") + value
        default: break
        }
        return nil
    }
}

// MARK: - Centaur Event Adapter

/// Maps Centaur's SSE vocabulary onto `GatewayEvent` so the chat pipeline
/// renders Centaur sessions unchanged.
///
///   session.execution_started    → messageStart
///   session.output.line          → messageDelta (line + \n)
///   session.execution_completed  → messageComplete(status: complete)
///   session.execution_failed     → messageComplete(status: error) + error
///   session.execution_cancelled  → messageComplete(status: interrupted)
///   session.stream_error         → statusUpdate (non-fatal; SSE loop retries)
///
/// Unknown event names (SessionEventName::Other passthrough) are checked for
/// a `hermes_event` envelope — the future path for a hermes-agent harness in
/// the sandbox to tunnel its full typed vocabulary through Centaur.
struct CentaurEventAdapter {

    private var accumulated = ""
    private var executionID: String?

    mutating func beginExecution(id: String?) {
        executionID = id
    }

    mutating func adapt(frame: SSEParser.Frame) -> [GatewayEvent] {
        switch frame.event {
        case "session.execution_started":
            accumulated = ""
            return [.messageStart]

        case "session.output.line":
            let line = frame.data + "\n"
            accumulated += line
            return [.messageDelta(text: line, rendered: nil)]

        case "session.execution_completed":
            return [finish(status: "complete")]

        case "session.execution_failed":
            let detail = payloadString(frame, key: "error") ?? "execution failed"
            return [finish(status: "error"), .error(message: detail)]

        case "session.execution_cancelled":
            return [finish(status: "interrupted")]

        case "session.first_token":
            return []

        case "session.stream_error":
            return [.statusUpdate(kind: "stream", text: "event stream error — reconnecting")]

        default:
            // Typed-event tunnel: a structured harness (hermes-agent) can emit
            // {"hermes_event": {"type": "...", "payload": {...}}} through
            // Centaur's Other(String) passthrough.
            if let tunneled = tunneledHermesEvent(frame) {
                return [tunneled]
            }
            return []
        }
    }

    private mutating func finish(status: String) -> GatewayEvent {
        let text = accumulated
        accumulated = ""
        return .messageComplete(payload: MessageCompletePayload(
            text: text,
            status: status,
            usage: nil,
            reasoning: nil,
            rendered: nil,
            warning: nil
        ))
    }

    private func payloadString(_ frame: SSEParser.Frame, key: String) -> String? {
        guard let data = frame.data.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj[key] as? String
    }

    private func tunneledHermesEvent(_ frame: SSEParser.Frame) -> GatewayEvent? {
        guard let data = frame.data.data(using: .utf8),
              let obj = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              let envelope = obj["hermes_event"]?.dictionaryValue,
              let type = envelope["type"]?.stringValue else {
            return nil
        }
        return GatewayEvent.from(type: type, payload: envelope["payload"])
    }
}
