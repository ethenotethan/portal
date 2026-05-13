import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "com.hermes-native", category: "Gateway")

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
    private var debugSnapshot: GatewayDebugSnapshot = GatewayDebugSnapshot()
    var onDebugSnapshotChange: (() -> Void)?
    var snapshotForDebug: GatewayDebugSnapshot { debugSnapshot }
    private var debugNotifyTask: Task<Void, Never>?
    private var debugNeedsNotify = false

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
    private var pendingRequestMethods: [Int: String] = [:]
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
        self.gatewayURL = URL(string: Constants.defaultGatewayURL) ?? URL(string: "ws://localhost:8642/v1/ws")!
        self.apiKey = ""
        super.init()
        refreshDebugSnapshot()
    }

    init(gatewayURL: URL, apiKey: String) {
        self.gatewayURL = gatewayURL
        self.apiKey = apiKey
        super.init()
        refreshDebugSnapshot()
    }

    // MARK: - Debug Telemetry

    private var stateDescription: String {
        switch connectionState {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reconnecting(let attempt): return "reconnecting #\(attempt)"
        case .error(let message): return "error: \(message)"
        }
    }

    private func refreshDebugSnapshot() {
        pendingRequestsLock.lock()
        let pendingIDs = pendingRequests.keys.sorted()
        let pendingMethods = pendingRequestMethods
        pendingRequestsLock.unlock()

        debugSnapshot.connectionState = stateDescription
        debugSnapshot.socketURL = gatewayURL.absoluteString
        debugSnapshot.isAuthenticated = !apiKey.isEmpty
        debugSnapshot.hasCFAuthCookie = cfAuthCookie != nil
        debugSnapshot.activeSessionID = activeSessionID
        debugSnapshot.lastSessionKey = lastSessionKey
        debugSnapshot.pendingRequestIDs = pendingIDs
        debugSnapshot.pendingRequestMethods = pendingMethods
        debugSnapshot.reconnectAttempt = reconnectAttempt
        scheduleDebugNotify()
    }

    private func recordDebugEvent(
        _ direction: GatewayDebugSnapshot.EventRecord.Direction,
        name: String,
        sessionID: String? = nil,
        detail: String = ""
    ) {
        let record = GatewayDebugSnapshot.EventRecord(
            timestamp: Date(),
            direction: direction,
            name: name,
            sessionID: sessionID,
            detail: detail
        )
        debugSnapshot.recentEvents.insert(record, at: 0)
        if debugSnapshot.recentEvents.count > 40 {
            debugSnapshot.recentEvents.removeLast(debugSnapshot.recentEvents.count - 40)
        }
        if direction == .error {
            debugSnapshot.lastErrorAt = record.timestamp
            debugSnapshot.lastError = detail.isEmpty ? name : detail
        }
        if direction == .dropped {
            let reason = detail.isEmpty ? "unspecified" : detail
            if let index = debugSnapshot.droppedEventReasons.firstIndex(where: { $0.reason == reason }) {
                debugSnapshot.droppedEventReasons[index].count += 1
                debugSnapshot.droppedEventReasons[index].lastAt = record.timestamp
            } else {
                debugSnapshot.droppedEventReasons.insert(
                    GatewayDebugSnapshot.DroppedEventReason(reason: reason, count: 1, lastAt: record.timestamp),
                    at: 0
                )
            }
            debugSnapshot.droppedEventReasons.sort { $0.lastAt > $1.lastAt }
            if debugSnapshot.droppedEventReasons.count > 12 {
                debugSnapshot.droppedEventReasons.removeLast(debugSnapshot.droppedEventReasons.count - 12)
            }
        }
        scheduleDebugNotify()
    }

    private func scheduleDebugNotify() {
        guard debugNotifyTask == nil else {
            debugNeedsNotify = true
            return
        }
        debugNeedsNotify = false
        debugNotifyTask = Task { @MainActor in
            onDebugSnapshotChange?()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            debugNotifyTask = nil
            if debugNeedsNotify {
                scheduleDebugNotify()
            }
        }
    }

    func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {
        recordDebugEvent(.dropped, name: event.debugName, sessionID: sessionID, detail: reason)
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
        refreshDebugSnapshot()
        recordDebugEvent(.state, name: "connect", detail: "opening")

        Task {
            // Always probe HTTP first so we fail fast with a useful status.
            let httpStatus = await probeHTTPHealth()
            if httpStatus == 404 {
                onLog?("⚠ HTTP health returned 404 — gateway may not have a WebSocket route at \(gatewayURL.path)", true)
                connectionState = .error(
                    "Gateway returned 404. The server does not have a WebSocket endpoint at \(gatewayURL.path). " +
                    "Check your gateway URL or server configuration."
                )
                return
            }
            // If HTTP is also failing (non-200, non-404), surface it but still try WS
            if httpStatus != 200 {
                onLog?("⚠ HTTP health returned \(httpStatus) — trying WS anyway", true)
            }

            // If we have a CF_Authorization cookie, verify it's still valid first
            if cfAuthCookie != nil {
                await verifyCFCookieThenConnect()
            } else {
                openWebSocket()
            }
        }
    }

    /// Quick HTTP HEAD to the gateway host to confirm reachability.
    /// Returns the HTTP status code, or -1 if the request itself failed.
    private func probeHTTPHealth() async -> Int {
        guard let host = gatewayURL.host,
              let scheme = gatewayURL.scheme else { return -1 }
        let healthURL = URL(string: "\(scheme)://\(host)/health")
            ?? URL(string: "\(scheme)://\(host)")
        guard let url = healthURL else { return -1 }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.httpMethod = "HEAD"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let cookie = cfAuthCookie {
            HTTPCookieStorage.shared.setCookie(cookie)
        }

        onLog?("Probing HTTP health at \(url)…", false)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            onLog?("HTTP health status: \(status)", status != 200)
            return status
        } catch {
            onLog?("HTTP health probe failed: \(error.localizedDescription)", true)
            return -1
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
        let url = gatewayURL, hasKey = !apiKey.isEmpty, hasCookie = cfAuthCookie != nil
        log.debug("Connecting to WS: \(url) auth=\(hasKey) cookie=\(hasCookie)")
        onLog?("Opening WebSocket to \(gatewayURL)…", false)

        // Clean up previous connection
        stopPingTimer()
        receiveTask?.cancel()
        receiveTask = nil

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpShouldUsePipelining = false

        // Carry CF_Authorization cookie
        if let cookie = cfAuthCookie {
            sessionConfig.httpCookieStorage?.setCookie(cookie)
        }

        var request = URLRequest(url: gatewayURL)
        if !apiKey.isEmpty {
            let authValue = "Bearer \(apiKey)"
            request.setValue(authValue, forHTTPHeaderField: "Authorization")
            // URLSessionWebSocketTask can drop URLRequest headers on some OS
            // releases even though the same code works on others. Keep the
            // header on both the upgrade request and the session config so the
            // API server auth path is reliable in iOS simulator/TestFlight.
            // This must be set before URLSession is created; configuration is
            // copied at init time.
            sessionConfig.httpAdditionalHeaders = ["Authorization": authValue]
        }

        let newSession = URLSession(configuration: sessionConfig, delegate: self, delegateQueue: nil)
        self.urlSession = newSession

        let task = newSession.webSocketTask(with: request)
        self.webSocketTask = task
        debugSnapshot.lastOpenAt = Date()
        refreshDebugSnapshot()
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
        pendingRequestMethods.removeAll()
        pendingRequestsLock.unlock()

        debugSnapshot.lastCloseAt = Date()
        refreshDebugSnapshot()

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
                log.debug("Ping failed: \(error)")
                Task { @MainActor in
                    self?.handleDisconnect(reason: "Ping failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Auto-Reconnect

    private func handleDisconnect(reason: String) {
        log.debug("Disconnected: \(reason)")
        stopPingTimer()
        debugSnapshot.lastCloseAt = Date()
        recordDebugEvent(.error, name: "disconnect", detail: reason)

        guard !isIntentionalDisconnect else { return }

        if reconnectAttempt >= Self.maxReconnectAttempts {
            onLog?("✗ Max reconnect attempts reached", true)
            connectionState = .error("Connection lost: \(reason). Max retries exceeded.")
            return
        }

        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), Self.maxReconnectDelay)
        connectionState = .reconnecting(attempt: reconnectAttempt)
        refreshDebugSnapshot()
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
            pendingRequestMethods[id] = method
            let count = pendingRequests.count
            log.debug("call: registered continuation for id=\(id), pending count=\(count)")
            pendingRequestsLock.unlock()
            refreshDebugSnapshot()

            // Send AFTER registration — continuation is now safe to fulfill.
            log.debug("call: sending \(method) id=\(id)")
            recordDebugEvent(.outbound, name: method, detail: "id=\(id)")
            onLog?("→ \(method) (id=\(id))", false)
            Task { @MainActor in
                do {
                    guard let jsonString = String(data: data, encoding: .utf8) else {
                        log.error("call: failed to encode JSON as UTF-8 for \(method) id=\(id)")
                        if self.removePendingRequest(id: id) != nil {
                            self.recordDebugEvent(.error, name: method, detail: "UTF-8 encode failed id=\(id)")
                            continuation.resume(throwing: GatewayError.invalidResponse("JSON UTF-8 encoding failed"))
                        }
                        return
                    }
                    try await webSocketTask.send(.string(jsonString))
                } catch {
                    // Send failed — remove continuation and propagate error.
                    // Only resume if it is still pending; a fast disconnect may
                    // already have resumed it via stopConnection().
                    if self.removePendingRequest(id: id) != nil {
                        self.recordDebugEvent(.error, name: method, detail: "send failed id=\(id): \(error.localizedDescription)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Convenience Methods

    /// Resolve gateway-reported Hermes capabilities with conservative fallback.
    func capabilities() async -> HermesCapabilities {
        let methods = ["gateway.capabilities", "hermes.capabilities", "hermes.version"]
        var lastError: String?

        for method in methods {
            do {
                let response = try await call(method)
                if let error = response.error {
                    lastError = "\(method): \(error.message)"
                    if error.code == JSONRPCError.methodNotFound.code {
                        continue
                    }
                    continue
                }
                return HermesCapabilities.from(result: response.result, method: method)
            } catch {
                lastError = "\(method): \(error.localizedDescription)"
                continue
            }
        }

        return HermesCapabilities.fallback(reason: lastError ?? "Capabilities RPC unsupported")
    }

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
        refreshDebugSnapshot()
        return sessionID
    }

    /// Set an ephemeral system prompt on the live agent for a session.
    /// The prompt is appended to the agent's system prompt on every API call
    /// but is NOT persisted to trajectories. Setting empty string clears it.
    func setEphemeralPrompt(sessionID: String, prompt: String) async throws {
        let response = try await call("session.set_prompt", params: [
            "session_id": AnyCodable(sessionID),
            "prompt": AnyCodable(prompt),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
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

            let endedAt: Date? = {
                if let ts = d["ended_at"]?.doubleValue, ts > 0 {
                    return Date(timeIntervalSince1970: ts)
                }
                return nil
            }()

            let lastActive: Date? = {
                if let ts = d["last_active"]?.doubleValue, ts > 0 {
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
                startedAt: startedAt,
                endedAt: endedAt,
                lastActive: lastActive,
                runState: SessionRunState(gatewayValue:
                    d["latest_run_state"]?.stringValue
                    ?? d["run_state"]?.stringValue
                    ?? d["state"]?.stringValue
                    ?? d["status"]?.stringValue
                )
            )
        }
    }

    /// List cron jobs via `cron.manage` with action "list".
    /// Gateway returns: {"success": true, "count": N, "jobs": [...]}
    /// Each job has: job_id, name, schedule, next_run_at (ISO8601), last_run_at (ISO8601),
    /// last_status, enabled, state, deliver, prompt_preview.
    func listCronJobs() async throws -> [CronJob] {
        let response = try await call("cron.manage", params: [
            "action": AnyCodable("list")
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let jobsArray = result["jobs"]?.arrayValue else {
            return []
        }

        let iso8601Formatter = ISO8601DateFormatter()
        iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return jobsArray.compactMap { item -> CronJob? in
            guard let d = item.dictionaryValue,
                  let jobID = d["job_id"]?.stringValue, !jobID.isEmpty else { return nil }

            let nextRunAt: Date? = {
                if let str = d["next_run_at"]?.stringValue {
                    return iso8601Formatter.date(from: str)
                }
                return nil
            }()

            let lastRunAt: Date? = {
                if let str = d["last_run_at"]?.stringValue {
                    return iso8601Formatter.date(from: str)
                }
                return nil
            }()

            let promptValue: String? = {
                let candidates = [
                    d["prompt"]?.stringValue,
                    d["full_prompt"]?.stringValue,
                    d["prompt_text"]?.stringValue,
                    d["cron_prompt"]?.stringValue,
                    d["command"]?.stringValue,
                    d["task"]?.stringValue,
                    d["script"]?.stringValue,
                    d["description"]?.stringValue,
                    d["body"]?.stringValue,
                    d["text"]?.stringValue,
                    d["message"]?.stringValue,
                    d["query"]?.stringValue,
                    d["content"]?.stringValue,
                    d["args"]?.stringValue,
                    d["input"]?.stringValue,
                    d["prompt_preview"]?.stringValue
                ]
                return candidates.compactMap { $0 }.first
            }()

            return CronJob(
                id: jobID,
                name: d["name"]?.stringValue ?? jobID,
                schedule: d["schedule"]?.stringValue ?? "",
                nextRunAt: nextRunAt,
                lastRunAt: lastRunAt,
                lastStatus: d["last_status"]?.stringValue,
                enabled: d["enabled"]?.boolValue ?? true,
                state: d["state"]?.stringValue ?? "scheduled",
                deliver: d["deliver"]?.stringValue ?? "local",
                promptPreview: d["prompt_preview"]?.stringValue,
                prompt: promptValue
            )
        }
    }

    // MARK: - Skills RPCs

    func listSkills() async throws -> [String: [String]] {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("list")
        ])
        if let error = response.error {
            log.error("listSkills: RPC error code=\(error.code) message=\(error.message)")
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }

        // Handle case where result is a string (e.g. "No skills configured")
        if let stringResult = response.result?.stringValue {
            log.info("listSkills: result is a string: '\(stringResult)'")
            return [:]
        }

        guard let result = response.result?.dictionaryValue else {
            log.info("listSkills: result is nil or not a dict, raw=\(String(describing: response.result))")
            return [:]
        }

        let keys = result.keys.sorted()
        log.info("listSkills: result keys=\(keys)")
        for k in keys {
            let v = result[k]
            log.info("listSkills: key=\(k) type=\(type(of: v)) value=\(String(describing: v))")
        }

        var categories: [String: [String]] = [:]

        // Gateway may return flat {category: [names]} or nested under "skills"/"categories" key
        let sourceDict: [String: AnyCodable]
        if let nested = result["skills"]?.dictionaryValue {
            sourceDict = nested
            log.info("listSkills: using nested 'skills' key")
        } else if let nested = result["categories"]?.dictionaryValue {
            sourceDict = nested
            log.info("listSkills: using nested 'categories' key")
        } else {
            sourceDict = result
            log.info("listSkills: using flat result dict")
        }

        for (key, value) in sourceDict {
            if key == "action" || key == "status" || key == "message" { continue }
            if let arr = value.arrayValue {
                let names = arr.compactMap { $0.stringValue }
                if !names.isEmpty {
                    categories[key] = names
                    log.info("listSkills: category=\(key) names=\(names)")
                }
            } else if let str = value.stringValue {
                categories[key] = [str]
                log.info("listSkills: category=\(key) single=\(str)")
            }
        }

        if categories.isEmpty {
            log.warning("listSkills: no categories parsed from \(sourceDict.count) source keys")
        }

        return categories
    }

    func scanSkillCommands() async throws -> [SkillInfo] {
        let response = try await call("commands.catalog")
        if let error = response.error {
            log.error("scanSkillCommands: RPC error code=\(error.code) message=\(error.message)")
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            log.info("scanSkillCommands: result is nil")
            return []
        }

        log.info("scanSkillCommands: result keys=\(result.keys.sorted())")

        var skills: [SkillInfo] = []
        if let pairs = result["commands"]?.arrayValue {
            for pair in pairs {
                guard let arr = pair.arrayValue, arr.count >= 2,
                      let key = arr[0].stringValue,
                      key.hasPrefix("/") else { continue }
                let desc = arr[1].stringValue ?? ""
                skills.append(SkillInfo(
                    name: key,
                    description: desc,
                    category: "general",
                    source: "local",
                    identifier: nil,
                    tags: [],
                    skillMdPath: nil,
                    skillDir: nil,
                    skillMdPreview: nil,
                    skillMdFullContent: nil,
                    slashCommand: key
                ))
            }
        }
        log.info("scanSkillCommands: found \(skills.count) skill commands")
        return skills
    }

    func inspectSkill(name: String) async throws -> SkillInfo? {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("inspect"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let infoDict = response.result?.dictionaryValue?["info"]?.dictionaryValue else { return nil }
        return SkillInfo.fromInspectDict(infoDict)
    }

    /// Read the full SKILL.md content for a skill.
    func readSkillMarkdown(name: String) async throws -> String {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("read"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue?["content"]?.stringValue
            ?? response.result?.stringValue
            ?? ""
    }

    /// Write (overwrite) the full SKILL.md content for a skill.
    func writeSkillMarkdown(name: String, content: String) async throws -> Bool {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("write"),
            "query": AnyCodable(name),
            "content": AnyCodable(content)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue?["success"]?.boolValue ?? true
    }

    func searchSkills(query: String) async throws -> [SkillSearchResult] {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("search"),
            "query": AnyCodable(query)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let results = response.result?.dictionaryValue?["results"]?.arrayValue else { return [] }
        return results.compactMap { SkillSearchResult.from($0.dictionaryValue ?? [:]) }
    }

    func installSkill(name: String) async throws -> Bool {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("install"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue?["installed"]?.boolValue ?? false
    }

    func uninstallSkill(name: String) async throws -> Bool {
        let response = try await call("skills.manage", params: [
            "action": AnyCodable("uninstall"),
            "query": AnyCodable(name)
        ])
        if let error = response.error {
            if error.code == 4017 {
                return try await uninstallSkillViaSlashExec(name)
            }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return true
    }

    private func uninstallSkillViaSlashExec(_ name: String) async throws -> Bool {
        let response = try await call("slash.exec", params: [
            "command": AnyCodable("skills uninstall \(name)"),
            "session_id": AnyCodable(activeSessionID ?? "")
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return true
    }

    func reloadSkills() async throws -> SkillsReloadResult {
        let response = try await call("skills.reload")
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            return SkillsReloadResult(output: "Reloaded", added: [], removed: [], total: 0)
        }
        let added = result["result"]?.dictionaryValue?["added"]?.arrayValue?.compactMap { $0.dictionaryValue?["name"]?.stringValue } ?? []
        let removed = result["result"]?.dictionaryValue?["removed"]?.arrayValue?.compactMap { $0.dictionaryValue?["name"]?.stringValue } ?? []
        let total = result["result"]?.dictionaryValue?["total"]?.intValue ?? 0
        let output = result["output"]?.stringValue ?? "Reloaded"
        return SkillsReloadResult(output: output, added: added, removed: removed, total: total)
    }

    // MARK: - Activity Inbox RPCs

    func listActivityItems(limit: Int = 100, includeRead: Bool = true, includeDismissed: Bool = false) async throws -> [ActivityItem] {
        let response = try await call("activity.list", params: [
            "limit": AnyCodable(limit),
            "include_read": AnyCodable(includeRead),
            "include_dismissed": AnyCodable(includeDismissed),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            if let arr = response.result?.arrayValue {
                return arr.compactMap { $0.dictionaryValue.flatMap(ActivityItem.from) }
            }
            return []
        }
        let itemsArray = result["items"]?.arrayValue
            ?? result["activities"]?.arrayValue
            ?? result["records"]?.arrayValue
        guard let itemsArray else {
            return []
        }
        return itemsArray.compactMap { $0.dictionaryValue.flatMap(ActivityItem.from) }
    }

    func markActivityRead(activityID: String, read: Bool = true) async throws -> ActivityItem {
        let response = try await call("activity.mark_read", params: [
            "activity_id": AnyCodable(activityID),
            "read": AnyCodable(read),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let activity = response.result?.dictionaryValue?["activity"]?.dictionaryValue.flatMap(ActivityItem.from) else {
            throw GatewayError.invalidResponse("missing activity in activity.mark_read response")
        }
        return activity
    }

    func dismissActivity(activityID: String) async throws -> ActivityItem {
        let response = try await call("activity.dismiss", params: [
            "activity_id": AnyCodable(activityID)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let activity = response.result?.dictionaryValue?["activity"]?.dictionaryValue.flatMap(ActivityItem.from) else {
            throw GatewayError.invalidResponse("missing activity in activity.dismiss response")
        }
        return activity
    }

    func getActivityArtifact(artifactID: String) async throws -> ActivityArtifactContent {
        let response = try await call("activity.artifacts.get", params: [
            "artifact_id": AnyCodable(artifactID)
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let artifact = response.result?.dictionaryValue?["artifact"]?.dictionaryValue.flatMap(ActivityArtifactContent.from) else {
            throw GatewayError.invalidResponse("missing artifact in activity.artifacts.get response")
        }
        return artifact
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

    /// Attach an image to the current session. Must be called before submitPrompt.
    /// The gateway validates the file extension and stores it in session state.
    func attachImage(path: String, sessionID: String? = nil) async throws {
        var params: [String: AnyCodable] = ["path": AnyCodable(path)]
        if let sid = sessionID {
            params["session_id"] = AnyCodable(sid)
        }
        let response = try await call("image.attach", params: params)
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

    /// Resume an existing session by database-format ID.
    /// Returns the new short hex session ID and any history messages from the gateway.
    /// The `sessionID` param should be the database-format ID (e.g., "20260501_112429_d91274").
    func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        let response = try await call("session.resume", params: [
            "session_id": AnyCodable(key),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let sessionID = result["session_id"]?.stringValue else {
            throw GatewayError.invalidResponse("missing session_id in session.resume response")
        }
        activeSessionID = sessionID
        refreshDebugSnapshot()

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

    /// Get session title + session_key (database ID) from the gateway.
    /// `session_id` param must be the short hex ID (gatewayID).
    /// Returns (title, sessionKey) where sessionKey is the database-format ID.
    func sessionTitle(sessionID: String) async throws -> (title: String, sessionKey: String?) {
        let response = try await call("session.title", params: [
            "session_id": AnyCodable(sessionID),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue else {
            return (title: "", sessionKey: nil)
        }
        let title = result["title"]?.stringValue ?? ""
        let sessionKey = result["session_key"]?.stringValue
        return (title: title, sessionKey: sessionKey)
    }

    /// Peek at a session owned by another transport.
    /// Uses `session.resume` to temporarily load the session, captures history
    /// and usage, then closes the peek session to clean up.
    /// IMPORTANT: This is expensive (creates a full agent) and overwrites the
    /// approval callback for the session_key. Use sparingly.
    func peekSession(sessionKey: String) async throws -> PeekResult {
        // 1. Resume with the database-format ID
        let response = try await call("session.resume", params: [
            "session_id": AnyCodable(sessionKey),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result?.dictionaryValue,
              let shortID = result["session_id"]?.stringValue else {
            throw GatewayError.invalidResponse("missing session_id in peek resume")
        }

        // 2. Parse messages from the resume response
        let messages = result["messages"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? []

        // 3. Get usage via the new short ID
        var usage: SessionUsage?
        if let usageResult = try? await sessionUsage(sessionID: shortID) {
            usage = usageResult
        }

        // 4. Close the peek session immediately
        _ = try? await call("session.close", params: [
            "session_id": AnyCodable(shortID),
        ])

        return PeekResult(
            sessionKey: sessionKey,
            gatewayID: shortID,
            messages: messages,
            usage: usage
        )
    }

    struct PeekResult {
        let sessionKey: String
        let gatewayID: String
        let messages: [[String: AnyCodable]]
        let usage: SessionUsage?
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
            log.debug("receiveLoop error: \(error)")
            switch connectionState {
            case .connecting:
                connectionState = .error(error.localizedDescription)
            case .connected, .reconnecting:
                let nsError = error as NSError
                if nsError.domain == NSPOSIXErrorDomain && nsError.code == 57 {
                    log.debug("receiveLoop ended after socket close; waiting for delegate close")
                    return
                }
                handleDisconnect(reason: error.localizedDescription)
            default:
                break
            }
        }
    }

    private func handleMessage(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.debug("handleMessage: failed to parse JSON")
            onLog?("⚠ Failed to parse WS message", true)
            return
        }

        // Response (has numeric "id" > 0)
        if let id = json["id"] as? Int, id > 0 {
            log.debug("handleMessage: response id=\(id)")
            onLog?("← response id=\(id)", false)
            if let responseData = try? JSONSerialization.data(withJSONObject: json),
               let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: responseData) {
                fulfillRequest(id: id, response: response)
                return
            }
            let raw = String(data: data, encoding: .utf8)?.prefix(300) ?? "nil"
            log.debug("handleMessage: failed to decode response for id=\(id), raw: \(raw)")
            onLog?("⚠ Decode failed for id=\(id): \(raw)", true)
            return
        }

        // Event (method == "event")
        if json["method"] as? String == "event",
           let params = json["params"] as? [String: Any],
           let type = params["type"] as? String {

            log.debug("handleMessage: event type=\(type)")
            if type != "message.delta" && type != "reasoning.delta" && type != "thinking.delta" {
                onLog?("← event: \(type)", false)
            }
            let payloadData: Data
            do {
                payloadData = try JSONSerialization.data(withJSONObject: params["payload"] ?? [:])
            } catch {
                log.error("JSONSerialization failed for event payload: \(error)")
                onLog?("⚠ Serialize failed for \(type): \(error.localizedDescription)", true)
                return
            }
            let payload: AnyCodable?
            do {
                payload = try JSONDecoder().decode(AnyCodable.self, from: payloadData)
            } catch {
                log.error("JSONDecoder failed for event payload: \(error)")
                onLog?("⚠ Decode failed for \(type): \(error.localizedDescription)", true)
                return
            }
            let event = GatewayEvent.from(type: type, payload: payload)
            let sessionID = params["session_id"] as? String
            recordDebugEvent(.inbound, name: type, sessionID: sessionID)

            if case .sessionInfo(let info) = event {
                sessionInfo = info
            }

            eventStream.send((event, sessionID))
        }
    }

    private func fulfillRequest(id: Int, response: JSONRPCResponse) {
        pendingRequestsLock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        let method = pendingRequestMethods.removeValue(forKey: id) ?? "response"
        let remaining = pendingRequests.count
        let found = continuation != nil
        log.debug("fulfillRequest: id=\(id), found=\(found), remaining=\(remaining)")
        pendingRequestsLock.unlock()
        recordDebugEvent(.inbound, name: method, detail: "response id=\(id)")

        continuation?.resume(returning: response)
    }

    /// Thread-safe removal of a pending request continuation.
    private func removePendingRequest(id: Int) -> CheckedContinuation<JSONRPCResponse, Error>? {
        pendingRequestsLock.lock()
        let continuation = pendingRequests.removeValue(forKey: id)
        pendingRequestMethods.removeValue(forKey: id)
        pendingRequestsLock.unlock()
        refreshDebugSnapshot()
        return continuation
    }

    // MARK: - URLSessionWebSocketDelegate

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { @MainActor in
            if let error = error as NSError? {
                let code = error.code
                let domain = error.domain
                let description = error.localizedDescription
                recordDebugEvent(.error, name: "websocket.failed", detail: "[\(domain) \(code)] \(description)")
                onLog?("✗ WebSocket handshake failed: [\(domain) \(code)] \(description)", true)

                // If it's a bad server response (-1011), try to read the HTTP status
                if code == NSURLErrorBadServerResponse,
                   let response = task.response as? HTTPURLResponse {
                    let status = response.statusCode
                    let headers = response.allHeaderFields
                    recordDebugEvent(.error, name: "websocket.http", detail: "status=\(status) headers=\(headers)")
                    onLog?("  HTTP status on upgrade: \(status)", true)
                }

                // Don't spin-reconnect on permanent errors
                if code == NSURLErrorBadServerResponse || code == NSURLErrorNotConnectedToInternet {
                    connectionState = .error("Server rejected connection (\(code): \(description))")
                    return
                }
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in
            onLog?("✓ WebSocket connected", false)
            connectionState = .connected
            reconnectAttempt = 0
            recordDebugEvent(.state, name: "websocket.open", detail: "connected")

            // Start keepalive pings
            startPingTimer()

            await onReconnected?()
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
            debugSnapshot.lastCloseAt = Date()
            recordDebugEvent(.state, name: "websocket.close", detail: "code=\(code.rawValue) \(reasonStr)")
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
