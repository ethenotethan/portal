import Foundation
import Combine

/// WebSocket client for the Hermes gateway JSON-RPC protocol.
///
/// Features:
/// - Ping/pong keepalive every 15s to prevent idle disconnects during long thinking
/// - Auto-reconnect with exponential backoff (1s → 2s → 4s → max 30s)
/// - Session resume on reconnect (preserves conversation context)
/// - Authenticates via Bearer token + optional CF_Authorization cookie on WS upgrade.
@MainActor
final class GatewayClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {

    // MARK: - Published State

    @Published var connectionState: ConnectionState = .disconnected
    @Published var sessionInfo: SessionInfo?

    // MARK: - Event Stream

    let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()

    /// Callback for connection log messages (shown in UI).
    var onLog: ((String, Bool) -> Void)?

    // MARK: - Types

    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting(attempt: Int)  // auto-reconnect in progress
        case error(String)
    }


    // MARK: - Delegation RPCs

    /// Get delegation status (active subagent counts, depth/cap limits).
    func delegationStatus() async throws -> [String: AnyCodable]? {
        let response = try await call("delegation.status")
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue
    }

    /// Interrupt a subagent by ID.
    func subagentInterrupt(subagentID: String, sessionID: String? = nil) async throws {
        var params: [String: AnyCodable] = ["subagent_id": AnyCodable(subagentID)]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("subagent.interrupt", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

        // MARK: - Spawn Tree RPCs

    /// List saved spawn tree snapshots. Set crossSession=true to list across all sessions.
    func spawnTreeList(sessionID: String? = nil, crossSession: Bool = false, limit: Int = 50) async throws -> [SpawnTreeEntry] {
        var params: [String: AnyCodable] = [
            "limit": AnyCodable(limit),
            "cross_session": AnyCodable(crossSession),
        ]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("spawn_tree.list", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let entries = result["entries"]?.arrayValue else {
            return []
        }
        return entries.compactMap { item -> SpawnTreeEntry? in
            guard let d = item.dictionaryValue else { return nil }
            return SpawnTreeEntry(
                path: d["path"]?.stringValue ?? "",
                sessionID: d["session_id"]?.stringValue ?? "",
                startedAt: d["started_at"]?.doubleValue,
                finishedAt: d["finished_at"]?.doubleValue ?? 0,
                label: d["label"]?.stringValue ?? "",
                subagentCount: d["count"]?.intValue ?? 0
            )
        }
    }

    /// Load a specific spawn tree snapshot by path.
    func spawnTreeLoad(path: String) async throws -> SpawnTreeSnapshot? {
        let response = try await call("spawn_tree.load", params: ["path": AnyCodable(path)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else { return nil }
        return SpawnTreeSnapshot.from(result)
    }

    /// Get usage stats for a session.
    func sessionUsage(sessionID: String) async throws -> SessionUsage? {
        let response = try await call("session.usage", params: ["session_id": AnyCodable(sessionID)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let d = response.result?.dictionaryValue else { return nil }
        return SessionUsage.from(d)
    }

    // MARK: - Private State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var requestIDCounter = 0
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private let pendingRequestsLock = NSLock()
    private var gatewayURL: URL
    private var apiKey: String

    /// CF_Authorization cookie from browser-based CF Access login.
    var cfAuthCookie: HTTPCookie?

    // MARK: - Keepalive

    private var pingTimer: Task<Void, Never>?
    private static let pingInterval: TimeInterval = 15  // seconds

    // MARK: - Reconnect

    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt: Int = 0
    private static let maxReconnectDelay: TimeInterval = 30
    private static let maxReconnectAttempts: Int = 10
    private var isIntentionalDisconnect = false

    // MARK: - Session Resume

    /// The session key from the last session.create — used to resume on reconnect.
    private(set) var lastSessionKey: String?
    /// The session ID currently in use.
    private(set) var activeSessionID: String?

    /// Callback for ChatViewModel to handle reconnection (resume vs create).
    var onReconnected: (() async -> Void)?

    // MARK: - Init

    override init() {
        self.gatewayURL = URL(string: Constants.defaultGatewayURL)!
        self.apiKey = ""
        super.init()
    }

    init(gatewayURL: URL, apiKey: String) {
        self.gatewayURL = gatewayURL
        self.apiKey = apiKey
        super.init()
    }

    // MARK: - Connection

    func connect() {
        let canConnect: Bool
        switch connectionState {
        case .disconnected, .error:
            canConnect = true
        default:
            canConnect = false
        }
        guard canConnect else { return }

        isIntentionalDisconnect = false
        reconnectAttempt = 0
        connectionState = .connecting

        // If we have a CF_Authorization cookie, verify it's still valid first
        if cfAuthCookie != nil {
            Task {
                await verifyCFCookieThenConnect()
            }
        } else {
            openWebSocket()
        }
    }

    /// Verify the CF_Authorization cookie is still valid via a quick HTTP check.
    private func verifyCFCookieThenConnect() async {
        guard let host = gatewayURL.host,
              let scheme = gatewayURL.scheme,
              let healthURL = URL(string: "\(scheme)://\(host)/health") else {
            openWebSocket()
            return
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // Attach CF cookie
        if let cookie = cfAuthCookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        onLog?("Verifying CF Access session…", false)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1

            if statusCode == 200 {
                onLog?("✓ CF Access session valid", false)
                openWebSocket()
            } else if statusCode == 302 || statusCode == 401 || statusCode == 403 {
                onLog?("⚠ CF Access session expired (HTTP \(statusCode)), re-auth needed", true)
                cfAuthCookie = nil
                connectionState = .error("CF Access session expired — please re-authenticate")
            } else {
                onLog?("⚠ Unexpected HTTP \(statusCode), trying WS anyway", false)
                openWebSocket()
            }
        } catch {
            onLog?("⚠ HTTP check failed: \(error.localizedDescription), trying WS anyway", false)
            openWebSocket()
        }
    }

    private func openWebSocket() {
        NSLog("[HermesNative] Connecting to WS: \(gatewayURL) auth=\(!apiKey.isEmpty) cookie=\(cfAuthCookie != nil)")
        onLog?("Opening WebSocket to \(gatewayURL)…", false)

        // Clean up previous connection
        stopPingTimer()
        receiveTask?.cancel()
        receiveTask = nil

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpShouldUsePipelining = false

        // Auth headers via httpAdditionalHeaders (URLSessionWebSocketTask
        // silently drops custom headers from URLRequest).
        var additionalHeaders: [String: String] = [:]
        if !apiKey.isEmpty {
            additionalHeaders["Authorization"] = "Bearer \(apiKey)"
        }
        if !additionalHeaders.isEmpty {
            sessionConfig.httpAdditionalHeaders = additionalHeaders
        }

        // Carry CF_Authorization cookie
        if let cookie = cfAuthCookie {
            sessionConfig.httpCookieStorage?.setCookie(cookie)
        }

        let newSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        self.urlSession = newSession

        let request = URLRequest(url: gatewayURL)
        let task = newSession.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        receiveTask = Task { [weak self] in
            await self?.receiveLoop()
        }
    }

    func disconnect() {
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        stopPingTimer()
        stopConnection()
    }

    private func stopConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        pendingRequestsLock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        pendingRequestsLock.unlock()

        for (_, cont) in pending {
            cont.resume(throwing: GatewayError.disconnected)
        }

        connectionState = .disconnected
    }

    // MARK: - Ping/Pong Keepalive

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pingInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await self?.sendPing()
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func sendPing() async {
        guard let task = webSocketTask else { return }
        task.sendPing { [weak self] error in
            if let error = error {
                NSLog("[HermesNative] Ping failed: \(error)")
                Task { @MainActor in
                    self?.handleDisconnect(reason: "Ping failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Auto-Reconnect

    private func handleDisconnect(reason: String) {
        NSLog("[HermesNative] Disconnected: \(reason)")
        stopPingTimer()

        guard !isIntentionalDisconnect else { return }

        if reconnectAttempt >= Self.maxReconnectAttempts {
            onLog?("✗ Max reconnect attempts reached", true)
            connectionState = .error("Connection lost: \(reason). Max retries exceeded.")
            return
        }

        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), Self.maxReconnectDelay)
        connectionState = .reconnecting(attempt: reconnectAttempt)
        onLog?("Reconnecting (attempt \(reconnectAttempt), \(String(format: "%.0f", delay))s)…", true)

        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.openWebSocket()
        }
    }

    // MARK: - JSON-RPC Calls

    func call(_ method: String, params: [String: AnyCodable]? = nil) async throws -> JSONRPCResponse {
        let id = nextRequestID()

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        guard let webSocketTask = webSocketTask else {
            throw GatewayError.notConnected
        }

        // Register continuation BEFORE sending so the response can't arrive
        // before we're ready to fulfill it (was the root cause of infinite hang).
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequestsLock.lock()
            pendingRequests[id] = continuation
            NSLog("[HermesNative] call: registered continuation for id=\(id), pending count=\(pendingRequests.count)")
            pendingRequestsLock.unlock()

            // Send AFTER registration — continuation is now safe to fulfill.
            NSLog("[HermesNative] call: sending \(method) id=\(id)")
            onLog?("→ \(method) (id=\(id))", false)
            Task { @MainActor in
                do {
                    try await webSocketTask.send(.string(String(data: data, encoding: .utf8)!))
                } catch {
                    // Send failed — remove continuation and propagate error
                    self.removePendingRequest(id: id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Convenience Methods

    /// Create a new agent session.
    func createSession(cols: Int = 120) async throws -> String {
        let response = try await call("session.create", params: ["cols": AnyCodable(cols)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let sessionID = result["session_id"]?.stringValue else {
            throw GatewayError.invalidResponse("missing session_id in session.create response")
        }
        // Save session key for resume on reconnect
        if let key = result["session_key"]?.stringValue {
            lastSessionKey = key
        }
        activeSessionID = sessionID
        return sessionID
    }

    /// List active sessions.
    /// Gateway returns: id, title, preview, started_at, message_count, source
    func listSessions() async throws -> [Session] {
        let response = try await call("session.list")
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let sessionsArray = result["sessions"]?.arrayValue else {
            return []
        }
        return sessionsArray.compactMap { item -> Session? in
            guard let d = item.dictionaryValue else { return nil }
            let id = d["id"]?.stringValue ?? ""
            guard !id.isEmpty else { return nil }

            let startedAt: Date? = {
                if let ts = d["started_at"]?.doubleValue, ts > 0 {
                    return Date(timeIntervalSince1970: ts)
                }
                return nil
            }()

            return Session(
                id: id,
                title: d["title"]?.stringValue,
                preview: d["preview"]?.stringValue,
                source: d["source"]?.stringValue,
                messageCount: d["message_count"]?.intValue ?? 0,
                startedAt: startedAt
            )
        }
    }

    func submitPrompt(sessionID: String, text: String) async throws {
        let response = try await call("prompt.submit", params: [
            "session_id": AnyCodable(sessionID),
            "text": AnyCodable(text),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    func interrupt(sessionID: String) async throws {
        let response = try await call("session.interrupt", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    func respondApproval(sessionID: String, choice: String, all: Bool = false) async throws {
        let response = try await call("approval.respond", params: [
            "session_id": AnyCodable(sessionID),
            "choice": AnyCodable(choice),
            "all": AnyCodable(all),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    func closeSession(sessionID: String) async throws {
        let response = try await call("session.close", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    /// Resume an existing session by key.
    /// Returns the new session ID and any history messages from the gateway.
    func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        let response = try await call("session.resume", params: [
            "session_key": AnyCodable(key),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let sessionID = result["session_id"]?.stringValue else {
            throw GatewayError.invalidResponse("missing session_id in session.resume response")
        }
        activeSessionID = sessionID

        // Parse history messages if present
        let historyMessages = result["messages"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? []
        return (sessionID: sessionID, messages: historyMessages)
    }

    /// Fetch conversation history for a session.
    func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] {
        let response = try await call("session.history", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            return []
        }
        return result["messages"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? []
    }

    func setConfig(key: String, value: String, sessionID: String? = nil) async throws {
        var params: [String: AnyCodable] = [
            "key": AnyCodable(key),
            "value": AnyCodable(value),
        ]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("config.set", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }


    // MARK: - Private

    /// Get a config value from the gateway.
    func getConfig(key: String) async throws -> [String: AnyCodable]? {
        let response = try await call("config.get", params: ["key": AnyCodable(key)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue
    }

    private func nextRequestID() -> Int {
        requestIDCounter += 1
        return requestIDCounter
    }

    private func receiveLoop() async {
        guard let webSocketTask = webSocketTask else { return }

        do {
            while true {
                let message = try await webSocketTask.receive()

                switch message {
                case .data(let data):
                    NSLog("[HermesNative] WS recv data: \(data.count) bytes")
                    handleMessage(data)

                case .string(let text):
                    NSLog("[HermesNative] WS recv string: \(text.prefix(200))")
                    if let data = text.data(using: .utf8) {
                        handleMessage(data)
                    }

                @unknown default:
                    break
                }
            }
        } catch {
            NSLog("[HermesNative] receiveLoop error: \(error)")
            switch connectionState {
            case .connecting:
                connectionState = .error(error.localizedDescription)
            case .connected, .reconnecting:
                handleDisconnect(reason: error.localizedDescription)
            default:
                break
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("[HermesNative] handleMessage: failed to parse JSON")
            onLog?("⚠ Failed to parse WS message", true)
            return
        }

        // Response (has numeric "id" > 0)
        if let id = json["id"] as? Int, id > 0 {
            NSLog("[HermesNative] handleMessage: response id=\(id)")
            onLog?("← response id=\(id)", false)
            if let responseData = try? JSONSerialization.data(withJSONObject: json),
               let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: responseData) {
                fulfillRequest(id: id, response: response)
                return
            }
            let raw = String(data: data, encoding: .utf8)?.prefix(300) ?? "nil"
            NSLog("[HermesNative] handleMessage: failed to decode response for id=\(id), raw: \(raw)")
            onLog?("⚠ Decode failed for id=\(id): \(raw)", true)
            return
        }

        // Event (method == "event")
        if json["method"] as? String == "event",
           let params = json["params"] as? [String: Any],
           let type = params["type"] as? String {

            NSLog("[HermesNative] handleMessage: event type=\(type)")
            onLog?("← event: \(type)", false)
            let payloadData = try? JSONSerialization.data(withJSONObject: params["payload"] ?? [:])
            let payload = payloadData.flatMap { try? JSONDecoder().decode(AnyCodable.self, from: $0) }
            let event = GatewayEvent.from(type: type, payload: payload)
            let sessionID = params["session_id"] as? String

            if case .sessionInfo(let info) = event {
                sessionInfo = info
            }

            eventStream.send((event, sessionID))
        }
    }

    private func fulfillRequest(id: Int, response: JSONRPCResponse) {
        pendingRequestsLock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        NSLog("[HermesNative] fulfillRequest: id=\(id), found=\(continuation != nil), remaining=\(pendingRequests.count)")
        pendingRequestsLock.unlock()

        continuation?.resume(returning: response)
    }

    /// Thread-safe removal of a pending request continuation (safe from async contexts).
    private nonisolated func removePendingRequest(id: Int) {
        MainActor.assumeIsolated {
            pendingRequests[id] = nil
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            onLog?("✓ WebSocket connected", false)
            connectionState = .connected
            reconnectAttempt = 0

            // Start keepalive pings
            startPingTimer()

            // Handle reconnection — try to resume previous session
            if let key = lastSessionKey {
                onLog?("Resuming session…", false)
                do {
                    let result = try await resumeSession(key: key)
                    activeSessionID = result.sessionID
                    onLog?("✓ Session resumed (\(result.messages.count) history messages)", false)
                    await onReconnected?()
                } catch {
                    onLog?("Resume failed, creating new session: \(error.localizedDescription)", true)
                    lastSessionKey = nil
                    await onReconnected?()
                }
            } else {
                await onReconnected?()
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            stopPingTimer()
            let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if case .connecting = connectionState {
                onLog?("✗ WebSocket closed during handshake: \(code) \(reasonStr)", true)
                connectionState = .error("Connection closed during handshake (code \(code.rawValue))")
            } else if isIntentionalDisconnect {
                connectionState = .disconnected
            } else {
                handleDisconnect(reason: "WebSocket closed (\(code.rawValue)) \(reasonStr)")
            }
        }
    }
}

// MARK: - Errors

enum GatewayError: LocalizedError {
    case notConnected
    case disconnected
    case invalidResponse(String)
    case rpcError(JSONRPCError)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to gateway"
        case .disconnected: "Connection lost"
        case .invalidResponse(let msg): "Invalid response: \(msg)"
        case .rpcError(let err): "RPC error [\(err.code)]: \(err.message)"
        }
    }
}
