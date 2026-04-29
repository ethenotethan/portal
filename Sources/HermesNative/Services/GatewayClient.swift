import Foundation
import Combine

/// WebSocket client for the Hermes gateway JSON-RPC protocol.
///
/// Connects to `wss://<host>/v1/ws` (or `ws://localhost:8642/v1/ws` for local).
/// Authenticates via Bearer token in the WS upgrade request.
/// All messages are newline-delimited JSON-RPC 2.0.
final class GatewayClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {

    // MARK: - Published State

    @Published nonisolated(unsafe) var connectionState: ConnectionState = .disconnected
    @Published nonisolated(unsafe) var sessionInfo: SessionInfo?

    // MARK: - Event Stream

    let eventStream = PassthroughSubject<GatewayEvent, Never>()

    // MARK: - Types

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    // MARK: - Private State

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var requestIDCounter = 0
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private let pendingRequestsLock = NSLock()
    private var receiveTask: Task<Void, Never>?

    // Auth
    private var gatewayURL: URL
    private var apiKey: String

    // MARK: - Init

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

        var request = URLRequest(url: gatewayURL)
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpShouldUsePipelining = false
        let newSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        self.urlSession = newSession

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

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        connectionState = .connected
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith code: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        connectionState = .disconnected
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
