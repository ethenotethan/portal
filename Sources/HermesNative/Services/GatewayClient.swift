import Foundation
import Combine

/// WebSocket client for the Hermes gateway JSON-RPC protocol.
///
/// Connects to `wss://<host>/v1/ws` (or `ws://localhost:8642/v1/ws` for local).
/// Authenticates via Bearer token + optional CF_Authorization cookie on WS upgrade.
/// All messages are newline-delimited JSON-RPC 2.0.
@MainActor
final class GatewayClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {

    // MARK: - Published State

    @Published var connectionState: ConnectionState = .disconnected
    @Published var sessionInfo: SessionInfo?

    // MARK: - Event Stream

    let eventStream = PassthroughSubject<GatewayEvent, Never>()

    /// Callback for connection log messages (shown in UI).
    var onLog: ((String, Bool) -> Void)?

    // MARK: - Types

    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
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

    // MARK: - JSON-RPC Calls

    func call(_ method: String, params: [String: AnyCodable]? = nil) async throws -> JSONRPCResponse {
        let id = nextRequestID()

        let request = JSONRPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)

        guard let webSocketTask = webSocketTask else {
            throw GatewayError.notConnected
        }

        try await webSocketTask.send(.data(data))
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequestsLock.lock()
            pendingRequests[id] = continuation
            pendingRequestsLock.unlock()
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
        return sessionID
    }

    /// List active sessions.
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
            return Session(
                id: d["session_id"]?.stringValue ?? "",
                key: d["session_key"]?.stringValue ?? "",
                model: d["model"]?.stringValue,
                isRunning: d["is_running"]?.boolValue ?? false
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
    func resumeSession(key: String) async throws -> String {
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
        return sessionID
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
                    handleMessage(data)

                case .string(let text):
                    if let data = text.data(using: .utf8) {
                        handleMessage(data)
                    }

                @unknown default:
                    break
                }
            }
        } catch {
            switch connectionState {
            case .connecting:
                connectionState = .error(error.localizedDescription)
            case .connected:
                connectionState = .disconnected
            default:
                break
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Response (has numeric "id" > 0)
        if let id = json["id"] as? Int, id > 0 {
            if let responseData = try? JSONSerialization.data(withJSONObject: json),
               let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: responseData) {
                fulfillRequest(id: id, response: response)
                return
            }
        }

        // Event (method == "event")
        if json["method"] as? String == "event",
           let params = json["params"] as? [String: Any],
           let type = params["type"] as? String {

            let payloadData = try? JSONSerialization.data(withJSONObject: params["payload"] ?? [:])
            let payload = payloadData.flatMap { try? JSONDecoder().decode(AnyCodable.self, from: $0) }
            let event = GatewayEvent.from(type: type, payload: payload)

            if case .sessionInfo(let info) = event {
                sessionInfo = info
            }

            eventStream.send(event)
        }
    }

    private func fulfillRequest(id: Int, response: JSONRPCResponse) {
        pendingRequestsLock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        pendingRequestsLock.unlock()

        continuation?.resume(returning: response)
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
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { @MainActor in
            let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if case .connecting = connectionState {
                onLog?("✗ WebSocket closed during handshake: \(code) \(reasonStr)", true)
                connectionState = .error("Connection closed during handshake (code \(code.rawValue))")
            } else {
                onLog?("WebSocket closed: \(code) \(reasonStr)", code != .normalClosure)
                connectionState = .disconnected
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
