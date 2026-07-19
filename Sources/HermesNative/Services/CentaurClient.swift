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

    /// REST has no transport to establish: the client is usable the moment
    /// it exists, so it reports `.connected` until a request/stream actually
    /// fails. Starting `.disconnected` deadlocks ChatViewModel.resumeSession,
    /// whose connected-guard runs BEFORE the resume call that would have
    /// flipped the state.
    @Published var connectionState: GatewayClient.ConnectionState = .connected
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

    /// Short-timeout session for REST calls. The long SSE timeout must NOT
    /// apply here: a create/execute POST against an unreachable host would
    /// otherwise hang the "creating session" state for up to an hour.
    private let restSession: URLSession
    /// Long-lived session for the SSE stream (never idle-timeout mid-stream).
    private let sseSession: URLSession

    /// Valid harness types per centaur-session-core's HarnessType enum
    /// (serde lowercase): "codex" | "amp" | "claudecode".
    init(baseURL: URL, apiKey: String, harnessType: String = "claudecode") {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.harnessType = harnessType

        let restConfig = URLSessionConfiguration.default
        restConfig.timeoutIntervalForRequest = 15
        self.restSession = URLSession(configuration: restConfig)

        let sseConfig = URLSessionConfiguration.default
        sseConfig.timeoutIntervalForRequest = 3600
        sseConfig.timeoutIntervalForResource = .infinity
        self.sseSession = URLSession(configuration: sseConfig)
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

    /// Percent-encode one path segment (thread keys contain ":").
    private func encodeSegment(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-_."))) ?? segment
    }

    private func sessionPath(_ threadKey: String, _ suffix: String = "") -> String {
        "api/session/\(encodeSegment(threadKey))\(suffix)"
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw GatewayError.invalidResponse("invalid Centaur URL path: \(path)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(apiKey, forHTTPHeaderField: "x-centaur-api-key")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await restSession.data(for: req)
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
        // validate_thread_key requires "<source>:<id>" namespacing — the
        // same convention as slack thread keys ("slack:C…:ts").
        let threadKey = "hermesnative:\(UUID().uuidString.prefix(12).lowercased())"
        do {
            _ = try await request("POST", sessionPath(threadKey), body: [
                "harness_type": harnessType,
            ])
        } catch {
            connectionState = .error(error.localizedDescription)
            throw error
        }
        activeSessionID = threadKey
        connectionState = .connected
        sessionInfo = Self.makeSessionInfo(harness: harnessType)
        // ChatViewModel consumes session info via the session-scoped
        // eventStream (sessionInfoPublisher has no session ID and is no
        // longer observed there), so emit it with the thread key.
        eventStream.send((.sessionInfo(Self.makeSessionInfo(harness: harnessType)), threadKey))
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
            _ = try await request("POST", sessionPath(key), body: [
                "harness_type": harnessType,
            ])
        } catch {
            connectionState = .error(error.localizedDescription)
            throw error
        }
        activeSessionID = key
        connectionState = .connected
        sessionInfo = Self.makeSessionInfo(harness: harnessType)
        eventStream.send((.sessionInfo(Self.makeSessionInfo(harness: harnessType)), key))
        startEventStream(threadKey: key)
        return (sessionID: key, messages: [])
    }

    func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] {
        // No transcript REST endpoint; SSE replay (after_event_id=0) is the
        // history mechanism. ChatViewModel treats an empty array as "nothing
        // extra to merge".
        []
    }

    // MARK: - Workflows

    /// List workflow runs (most recent first, server-side limit).
    /// 404/501 → empty: the deployment has no workflow runtime enabled.
    func workflowRuns(limit: Int = 50) async throws -> [CentaurWorkflowRun] {
        let data: Data
        do {
            data = try await request("GET", "api/workflows/runs?limit=\(limit)")
        } catch let error as GatewayError {
            if case .rpcError(let rpc) = error, rpc.code == 404 || rpc.code == 501 { return [] }
            throw error
        }
        struct Envelope: Decodable { let runs: [CentaurWorkflowRun] }
        return try JSONDecoder().decode(Envelope.self, from: data).runs
    }

    /// Registered workflow schedules (the standing definitions).
    func workflowSchedules() async throws -> [CentaurWorkflowSchedule] {
        let data: Data
        do {
            data = try await request("GET", "api/workflows/schedules")
        } catch let error as GatewayError {
            if case .rpcError(let rpc) = error, rpc.code == 404 || rpc.code == 501 { return [] }
            throw error
        }
        struct Envelope: Decodable { let schedules: [CentaurWorkflowSchedule] }
        return try JSONDecoder().decode(Envelope.self, from: data).schedules
    }

    /// Fetch one run's current state (poll target for active runs).
    func workflowRun(runID: String) async throws -> CentaurWorkflowRun? {
        let data = try await request("GET", "api/workflows/runs/\(encodeSegment(runID))")
        struct Envelope: Decodable { let run: CentaurWorkflowRun }
        return try? JSONDecoder().decode(Envelope.self, from: data).run
    }

    /// Cancel an active run.
    func cancelWorkflowRun(runID: String) async throws {
        _ = try await request("POST", "api/workflows/runs/\(encodeSegment(runID))/cancel")
    }

    func interrupt(sessionID: String) async throws {
        _ = try await request("POST", sessionPath(sessionID, "/interrupt"), body: [
            "reason": "user interrupt from HermesNative",
        ])
    }

    // MARK: - Conversation

    func submitPrompt(sessionID: String, text: String) async throws {
        // SessionMessageInput: role + parts (Vec<Value>). Parts follow the
        // convention centaur's own bots use: [{type: "text", text: …}].
        _ = try await request("POST", sessionPath(sessionID, "/messages"), body: [
            "messages": [[
                "client_message_id": UUID().uuidString,
                "role": "user",
                "parts": [["type": "text", "text": text]],
            ]],
        ])
        // input_lines feed the harness adapter's stdin in "blocks mode":
        // each line is a JSON envelope (type/thread_key/message with content
        // blocks) — raw text is rejected with "invalid blocks-mode input".
        // Mirrors slackbotv2's toCodexInputLine.
        let envelope: [String: Any] = [
            "type": "user",
            "thread_key": sessionID,
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]],
            ],
        ]
        let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
        guard let envelopeLine = String(bytes: envelopeData, encoding: .utf8) else {
            throw GatewayError.invalidResponse("failed to encode input line")
        }
        let data = try await request("POST", sessionPath(sessionID, "/execute"), body: [
            "idempotency_key": UUID().uuidString,
            "input_lines": [envelopeLine],
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
        let (data, _) = try await restSession.data(from: url)
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
                guard let base = URL(string: sessionPath(threadKey, "/events"), relativeTo: baseURL) else { return }
                var req = URLRequest(url: base
                    .appending(queryItems: [URLQueryItem(name: "after_event_id", value: String(after))]))
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                req.setValue(apiKey, forHTTPHeaderField: "x-centaur-api-key")
                req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                let (bytes, response) = try await sseSession.bytes(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw GatewayError.invalidResponse("SSE connect failed")
                }
                if attempt > 0 { await onReconnected?() }
                attempt = 0
                connectionState = .connected

                // Manual line framing: AsyncBytes.lines SKIPS empty lines,
                // and the empty line is exactly what terminates an SSE frame —
                // using it means no frame ever completes and no event is
                // delivered. Split on \n ourselves.
                var parser = SSEParser()
                var lineBuffer: [UInt8] = []
                for try await byte in bytes {
                    guard !Task.isCancelled else { return }
                    if byte == UInt8(ascii: "\n") {
                        var lineBytes = lineBuffer
                        lineBuffer.removeAll(keepingCapacity: true)
                        if lineBytes.last == UInt8(ascii: "\r") {
                            lineBytes.removeLast()
                        }
                        guard let line = String(bytes: lineBytes, encoding: .utf8) else { continue }
                        guard let frame = parser.consume(line: line) else { continue }
                        if let id = frame.id, let numeric = Int64(id) {
                            lastEventID[threadKey] = numeric
                        }
                        for event in adapter.adapt(frame: frame) {
                            eventStream.send((event, threadKey))
                        }
                    } else {
                        lineBuffer.append(byte)
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
///   session.output.line          → parsed as a harness NDJSON frame
///   session.execution_completed  → messageComplete(status: complete)
///   session.execution_failed     → messageComplete(status: error) + error
///   session.execution_cancelled  → messageComplete(status: interrupted)
///   session.stream_error         → statusUpdate (non-fatal; SSE loop retries)
///
/// Output lines from CLI harnesses (Claude Code app-server, codex) are an
/// NDJSON protocol stream — {"method": "item/agentMessage/delta", …} — not
/// prose. Each JSON line routes through `adaptHarnessFrame`; non-JSON lines
/// fall back to raw text passthrough for plain-text harnesses.
///
/// Unknown event names (SessionEventName::Other passthrough) are checked for
/// a `hermes_event` envelope — the future path for a hermes-agent harness in
/// the sandbox to tunnel its full typed vocabulary through Centaur.
struct CentaurEventAdapter {

    /// Accumulated assistant text (deltas), replaced by the authoritative
    /// final text from item/completed when the harness provides it.
    private var accumulated = ""
    private var finalText: String?
    private var executionID: String?

    mutating func beginExecution(id: String?) {
        executionID = id
    }

    mutating func adapt(frame: SSEParser.Frame) -> [GatewayEvent] {
        switch frame.event {
        case "session.execution_started":
            accumulated = ""
            finalText = nil
            return [.messageStart]

        case "session.output.line":
            return adaptOutputLine(frame.data)

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

    // MARK: - Harness NDJSON

    private mutating func adaptOutputLine(_ line: String) -> [GatewayEvent] {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String else {
            // Plain-text harness output: stream the line verbatim.
            let text = line + "\n"
            accumulated += text
            return [.messageDelta(text: text, rendered: nil)]
        }
        let params = obj["params"] as? [String: Any] ?? [:]
        return adaptHarnessFrame(method: method, params: params)
    }

    private mutating func adaptHarnessFrame(method: String, params: [String: Any]) -> [GatewayEvent] {
        switch method {
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            accumulated += delta
            return [.messageDelta(text: delta, rendered: nil)]

        case "item/reasoning/delta", "item/thinking/delta":
            guard let delta = params["delta"] as? String, !delta.isEmpty else { return [] }
            return [.thinkingDelta(text: delta)]

        case "item/started", "item/completed", "item/updated":
            return adaptItemLifecycle(method: method, params: params)

        case "turn/completed":
            // The SSE-level execution_completed follows and produces the
            // messageComplete; here we only capture the turn's final status.
            return []

        case "error":
            let detail = (params["error"] as? [String: Any])?["message"] as? String
                ?? "harness error"
            return [.error(message: detail)]

        case "thread/started", "turn/started":
            return []

        default:
            return []
        }
    }

    /// Item lifecycle: agent messages carry the final text; user echoes are
    /// dropped; anything else (tool calls, command executions, file edits)
    /// renders as a tool row so the existing tool UI works on Centaur.
    private mutating func adaptItemLifecycle(method: String, params: [String: Any]) -> [GatewayEvent] {
        guard let item = params["item"] as? [String: Any],
              let type = item["type"] as? String else { return [] }
        let itemID = item["id"] as? String ?? UUID().uuidString

        switch type {
        case "userMessage":
            return []  // echo of our own input

        case "agentMessage":
            if method == "item/completed", let text = item["text"] as? String, !text.isEmpty {
                finalText = text
            }
            return []

        default:
            // Tool-ish item (toolCall / commandExecution / fileEdit / …).
            let name = item["name"] as? String ?? item["title"] as? String ?? type
            let preview = item["command"] as? String
                ?? item["text"] as? String
                ?? item["path"] as? String
                ?? ""
            if method == "item/started" {
                return [.toolStart(payload: ToolStartPayload(
                    toolID: itemID, name: name, context: preview
                ))]
            }
            if method == "item/completed" {
                return [.toolComplete(payload: ToolCompletePayload(
                    toolID: itemID, name: name,
                    summary: preview, durationSeconds: nil, inlineDiff: nil,
                    todos: nil
                ))]
            }
            return []
        }
    }

    private mutating func finish(status: String) -> GatewayEvent {
        // Prefer the harness's authoritative final text over accumulated
        // deltas (deltas can be lossy across an SSE reconnect).
        let text = finalText ?? accumulated
        accumulated = ""
        finalText = nil
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
