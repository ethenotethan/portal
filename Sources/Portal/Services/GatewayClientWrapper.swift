import Combine
import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.ethenotethan.Portal", category: "GatewayClientWrapper")

/// Observable wrapper for the app-level GatewayClient lifecycle.
///
/// Portal uses one persistent WebSocket per app process. Sessions are
/// multiplexed over that socket by RPC/event `session_id`; creating/selecting a
/// session must not recreate the transport.
@MainActor
final class GatewayClientWrapper: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var log: [LogEntry] = []
    /// The current auto-reconnect attempt when the client is retrying after a
    /// drop, else nil. Published separately from `isConnecting` because both
    /// `.connecting` and `.reconnecting` set that flag: surfaces keyed on it
    /// alone rendered a plain "Connecting…" while the client was actually in an
    /// endless retry loop, which is exactly what "it just hangs on Connecting"
    /// looked like. Distinguishing them makes progress (or its absence) visible.
    @Published internal private(set) var reconnectAttempt: Int?
    /// The terminal message when reconnect attempts are exhausted, else nil.
    /// Surfaces show this instead of an indefinite spinner so a dead harness
    /// ends in something the user can act on rather than a permanent wait.
    @Published internal private(set) var connectionErrorMessage: String?
    /// Mirrors the current client's keepalive RTT so views observing the
    /// wrapper (not the inner client, which is swapped on reconnect) can
    /// show live latency.
    @Published private(set) var lastPingRTT: TimeInterval?
    /// The live transport. Published: the client is REPLACED (not mutated) on
    /// every gateway switch, and views resolving the current backend through
    /// `liveClient(for:)` must re-render on the swap — otherwise a harness's
    /// status row keeps reading the previous gateway's client.
    @Published internal private(set) var client: GatewayClient

    /// How long to wait for a socket to open before treating the attempt as
    /// failed. MUST outlast `GatewayClient.handshakeTimeout`, or the wait
    /// expires while the dial is still legitimately in progress and the caller
    /// concludes "failed" before the transport can report why.
    ///
    /// This was 12s against a 15s handshake, which is the "Connecting,
    /// connecting, connecting…" bug. Measured against a black-holed host,
    /// URLSession delivered `-1004` at 12.32s — just after the 12s wait gave
    /// up. `connectWithRetry` then called `connectIfNeeded(force: true)`, which
    /// throws the in-flight client away and builds a NEW `GatewayClient`
    /// (another `connect` event, another `.connecting`). So the failure never
    /// landed on a client anyone was still listening to: `handleDisconnect`
    /// never ran, `reconnectAttempt` stayed 0, and the reconnect state machine —
    /// including the success-gated budget — was never reached at all.
    ///
    /// The margin is deliberately generous rather than a hair over 15s: the
    /// handshake timeout bounds URLSession's own request, and the observed
    /// callback ran ~1.3s past it.
    internal static let connectWaitTimeout: TimeInterval = GatewayClient.handshakeTimeout + 5

    /// One label for every surface that shows transport status from the
    /// wrapper's flags (toolbar tooltip, menu bar, wiki placeholder). They all
    /// used to hardcode "Connecting…" off `isConnecting` alone, so three
    /// different states — first dial, endless retry, and terminal failure — were
    /// indistinguishable. Centralized so they can't drift apart again.
    internal var statusLabel: String {
        if isConnected { return "Connected" }
        if let attempt = reconnectAttempt {
            return "Reconnecting… (attempt \(attempt) of \(GatewayClient.maxReconnectAttempts))"
        }
        if isConnecting { return "Connecting…" }
        if let message = connectionErrorMessage { return message }
        return "Disconnected"
    }

    private var pingRTTCancellable: AnyCancellable?
    private var connectionCancellable: AnyCancellable?
    private var connectTask: Task<Void, Never>?
    private var currentSignature: ConnectionSignature?

    /// Lazily-created session-scoped clients, keyed by backend entry ID.
    /// Independent of the WebSocket lifecycle above — these backends are
    /// stateless until a session opens its stream. Rebuilt when the entry's
    /// url/key change.
    private var scopedClients: [UUID: (signature: String, client: any AgentBackend)] = [:]

    /// Returns the client for a saved session-scoped backend entry, or nil
    /// when the entry isn't session-scoped or has an invalid URL. Dispatches
    /// on kind — the only place that maps kinds to client types.
    func sessionScopedBackend(for entry: SavedGateway) -> (any AgentBackend)? {
        // httpOrigin, not URL(string:): the old check passed anything with a
        // scheme, and a bare "host:8080" satisfies that with the HOST as the
        // scheme — producing a client dialing nowhere.
        guard entry.kind.isSessionScoped,
              let url = GatewayURL.httpOrigin(entry.url) else {
            return nil
        }
        let signature = "\(url.absoluteString)|\(entry.apiKey)"
        if let existing = scopedClients[entry.id], existing.signature == signature {
            return existing.client
        }
        let client: any AgentBackend
        switch entry.kind {
        case .hermes, .hermesStandard:
            return nil  // management/app backends are never session-scoped
        case .centaur:
            client = CentaurClient(baseURL: url, apiKey: entry.apiKey)
        }
        scopedClients[entry.id] = (signature, client)
        appendLog("Session backend: \(entry.displayName) (\(url.absoluteString))")
        return client
    }

    /// Live chat clients for focused Hermes Standard backends, keyed by entry
    /// ID. A Standard chat client is a *second*, independent WebSocket to the
    /// dashboard's `/api/ws` sidecar — the app-level Hermes socket above stays
    /// connected underneath so ambient services (HTTP cron/skills, the home
    /// session list) keep working while chat targets Standard. Rebuilt when the
    /// entry's URL/token change.
    private var standardChatClients: [UUID: (signature: String, client: GatewayClient)] = [:]

    /// Returns a connected `GatewayClient` for a focused Hermes Standard
    /// backend's chat sidecar, or nil when the entry isn't Standard or its URL
    /// can't form a `/api/ws` endpoint. The upstream sidecar is wire-compatible
    /// with the Hermes gateway (newline-delimited JSON-RPC), so a plain
    /// `GatewayClient` drives it — no bespoke backend needed. Auth rides as the
    /// `?token=` query item built into the URL.
    ///
    /// Note: the server gates `/api/ws` behind an embedded-chat opt-in and
    /// closes with 4403 when it's off (4401 on a bad token). The returned
    /// client surfaces that as a connection error like any other WS failure.
    internal func standardChatClient(for entry: SavedGateway) -> GatewayClient? {
        guard entry.kind == .hermesStandard, let wsURL = entry.hermesStandardChatURL else {
            return nil
        }
        let signature = wsURL.absoluteString
        if let existing = standardChatClients[entry.id], existing.signature == signature {
            return existing.client
        }
        // URL/token changed — tear down the stale socket before replacing it.
        standardChatClients[entry.id]?.client.disconnect()
        // The token travels in the URL query, so the client's apiKey stays empty
        // (an empty Bearer header would otherwise be sent and ignored).
        let client = GatewayClient(gatewayURL: wsURL, apiKey: "")
        standardChatClients[entry.id] = (signature, client)
        client.connect()
        appendLog("Standard chat: \(entry.displayName) (\(wsURL.absoluteString))")
        return client
    }

    /// Tear down every Standard chat socket (e.g. when leaving all Standard
    /// focus). Idempotent; the app-level Hermes socket is unaffected.
    internal func disconnectStandardChatClients() {
        for (_, entry) in standardChatClients {
            entry.client.disconnect()
        }
        standardChatClients.removeAll()
    }

    /// The live backend currently serving this entry, for status/diagnostics
    /// display — or nil when nothing is connected on its behalf. Read-only:
    /// unlike `standardChatClient(for:)`/`sessionScopedBackend(for:)`, this
    /// never builds or connects a client, so a settings pane can show "offline"
    /// without spinning up a socket. Resolution mirrors where each kind's
    /// transport lives:
    /// - `.hermes` — the app-level socket, but only while this entry is the
    ///   active home gateway (`isActive`); other Hermes entries aren't dialed.
    /// - `.hermesStandard` — its `/api/ws` chat sidecar, once focused.
    /// - session-scoped — its lazily-built client, once a session has opened.
    internal func liveClient(for entry: SavedGateway, isActive: Bool) -> (any AgentBackend)? {
        switch entry.kind {
        case .hermes:
            return isActive ? client : nil
        case .hermesStandard:
            return standardChatClients[entry.id]?.client
        case .centaur:
            return scopedClients[entry.id]?.client
        }
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private struct ConnectionSignature: Equatable {
        let url: String
        let apiKey: String
        let cfCookieValue: String?
    }

    init() {
        self.client = GatewayClient()
    }

    @discardableResult
    func connectIfNeeded(using settings: SettingsViewModel, force: Bool = false) async -> Bool {
        guard let wsURL = settings.buildWebSocketURL() else {
            // Tear the old socket down. Bailing out with it still live is what
            // made a rejected address look like it was "resolved to localhost":
            // `client` still pointed at the PREVIOUS gateway — on a cold launch
            // the loopback default — so the app stayed happily connected there
            // while Settings displayed the address the user had just typed. The
            // session list, cron jobs, and wiki all came from the wrong harness.
            // Disconnecting makes the failure look like the failure it is.
            client.disconnect()
            currentSignature = nil
            isConnecting = false
            isConnected = false
            appendLog(
                "✗ Can't read “\(settings.gatewayURL)” as a harness address — "
                    + "expected something like 100.94.3.17:8642 or wss://host/v1/ws",
                error: true
            )
            return false
        }
        let forceStr = String(describing: force)
        let urlStr = String(describing: wsURL)
        let keySet = String(describing: !settings.apiKey.isEmpty)
        let isConnectedStr = String(describing: self.isConnected)
        let isConnectingStr = String(describing: self.isConnecting)
        let hasTaskStr = String(describing: self.connectTask != nil)
        let msg = [
            "force=\(forceStr)",
            "url=\(urlStr)",
            "apiKeySet=\(keySet)",
            "currentConnected=\(isConnectedStr)",
            "isConnecting=\(isConnectingStr)",
            "hasTask=\(hasTaskStr)",
        ].joined(separator: " ")
        logger.info("GatewayClientWrapper connectIfNeeded \(msg)")

        let signature = ConnectionSignature(
            url: wsURL.absoluteString,
            apiKey: settings.apiKey,
            cfCookieValue: settings.cfAuthCookie?.value
        )

        // An explicit connection request grants auto-reconnect a fresh budget,
        // so a client that exhausted its retries (terminal .error) resumes
        // reconnecting instead of staying dead until app restart (#178).
        //
        // force: this call IS the user (or a launch/foreground path) asking to
        // connect, which outranks the success gate. Note it doesn't reopen the
        // infinite loop the gate closed: below, an unchanged signature with a
        // live-but-failing connection returns through the in-flight branch
        // rather than dialing again, so the grant is not renewed on a timer.
        resetReconnectBudget(force: true)

        if !force, currentSignature == signature {
            if isConnected { return true }
            if isConnecting || connectTask != nil {
                let connected = await waitUntilConnected(timeout: Self.connectWaitTimeout)
                logger.info("GatewayClientWrapper reused in-flight connection result=\(connected)")
                if connected { return true }
                // An armed backoff is not a wedge — it's the retry path doing
                // its job. Rebuilding here hands back a client with a zeroed
                // counter, which is how the loop became unbounded; report
                // failure and let the existing schedule reach a connection or
                // the attempt cap.
                if reconnectAttempt != nil {
                    logger.info("GatewayClientWrapper deferring to armed reconnect; not rebuilding")
                    return false
                }
                // The in-flight connect is genuinely wedged (isConnecting never
                // clears and no backoff is armed). Returning failure here would
                // leave every later call queueing behind the same doomed wait —
                // fall through and rebuild the transport instead (#178).
                logger.info("GatewayClientWrapper in-flight connection wedged; rebuilding transport")
            }
        }

        if let existing = connectTask, !existing.isCancelled {
            existing.cancel()
            connectTask = nil
            isConnecting = false
        }

        currentSignature = signature
        isConnecting = true
        isConnected = false
        log.removeAll()

        appendLog("URL: \(wsURL.absoluteString)")
        appendLog("API key: \(settings.apiKey.isEmpty ? "none" : "set (\(settings.apiKey.prefix(8))…)")")
        appendLog("CF Access: \(settings.cfAuthCookie != nil ? "authenticated" : "not set")")

        // Recreate the transport only when settings actually change (or force).
        client.disconnect()
        let newClient = GatewayClient(gatewayURL: wsURL, apiKey: settings.apiKey)
        newClient.cfAuthCookie = settings.cfAuthCookie
        client = newClient
        observeConnectionState(of: newClient)

        newClient.onLog = { [weak self] message, isError in
            Task { @MainActor in
                self?.appendLog(message, error: isError)
            }
        }

        connectTask = Task { @MainActor [weak self, weak newClient] in
            newClient?.connect()
            let connected = await self?.waitUntilConnected(timeout: Self.connectWaitTimeout) ?? false
            guard !Task.isCancelled else { return }
            self?.isConnecting = false
            self?.connectTask = nil
            if !connected, newClient === self?.client {
                self?.appendLog("✗ Timed out waiting for WebSocket connection", error: true)
            }
        }

        let connected = await waitUntilConnected(timeout: Self.connectWaitTimeout)
        logger.info("GatewayClientWrapper new connection result=\(connected)")
        return connected
    }

    /// Connect with a small bounded retry for cold-start races where the
    /// network path isn't up yet (iOS launch, foreground radio wake). A failed
    /// attempt leaves GatewayClient in a terminal `.error`/`.connecting` state
    /// with no automatic retry — auto-reconnect only arms after a successful
    /// connection — so retry with backoff here. Attempts: immediate, +2s, +4s.
    @discardableResult
    func connectWithRetry(using settings: SettingsViewModel, maxAttempts: Int = 3) async -> Bool {
        var delay: TimeInterval = 2
        for attempt in 1...maxAttempts {
            let connected = await connectIfNeeded(using: settings, force: attempt > 1)
            if connected { return true }
            guard attempt < maxAttempts else { break }
            // Once the transport's own auto-reconnect has taken over, stop
            // dialing. Each `force` rebuild replaces the client with a fresh one
            // whose attempt counter is 0, so retrying here on top of an active
            // backoff produced an unbounded sequence of new `connect`s — the
            // "connecting, connecting, connecting" the debug log showed — and
            // starved the state machine that would otherwise reach the cap.
            if reconnectAttempt != nil {
                logger.info("connectWithRetry yielding to auto-reconnect (attempt \(self.reconnectAttempt ?? 0))")
                return await waitUntilConnected(timeout: Self.connectWaitTimeout)
            }
            logger.info("connectWithRetry attempt \(attempt) failed; retrying in \(delay)s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return isConnected }
            if isConnected { return true }
            delay *= 2
        }
        return isConnected
    }

    internal func connectedClient(
        using settings: SettingsViewModel,
        timeout seconds: TimeInterval = GatewayClientWrapper.connectWaitTimeout
    ) async -> GatewayClient? {
        guard await connectIfNeeded(using: settings) else { return nil }
        guard await waitUntilConnected(timeout: seconds) else { return nil }
        return client
    }

    /// Legacy name kept for callers that intentionally want to connect.
    func connect(using settings: SettingsViewModel) async {
        _ = await connectIfNeeded(using: settings)
    }

    /// Forward to the current client: give auto-reconnect a fresh attempt
    /// budget. Called on app foreground and inside connectIfNeeded so an
    /// exhausted retry cap never survives a user-visible trigger (#178).
    ///
    /// `force` distinguishes an explicit connect request from an ambient
    /// trigger like window focus; unforced grants apply only after a socket has
    /// actually opened. See `GatewayClient.resetReconnectBudget`.
    internal func resetReconnectBudget(force: Bool = false) {
        client.resetReconnectBudget(force: force)
    }

    /// On wake/foreground, verify the socket is actually live (a half-open
    /// connection still reports `.connected`) and force a fresh transport if
    /// not — so the user's next action can't beachball on a dead socket.
    internal func verifyLivenessOrReconnect() async {
        await client.verifyLivenessOrReconnect()
        isConnected = isClientConnected
    }

    func waitUntilConnected(timeout seconds: TimeInterval = 10) async -> Bool {
        if isClientConnected {
            isConnected = true
            isConnecting = false
            return true
        }

        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if isClientConnected {
                isConnected = true
                isConnecting = false
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        isConnected = isClientConnected
        return isConnected
    }

    private var isClientConnected: Bool {
        if case .connected = client.connectionState {
            return true
        }
        return false
    }

    private func observeConnectionState(of observedClient: GatewayClient) {
        pingRTTCancellable = observedClient.$lastPingRTT
            .receive(on: RunLoop.main)
            .sink { [weak self, weak observedClient] rtt in
                guard let self, observedClient === self.client else { return }
                self.lastPingRTT = rtt
            }
        connectionCancellable = observedClient.$connectionState
            .receive(on: RunLoop.main)
            .sink { [weak self, weak observedClient] state in
                guard let self, observedClient === self.client else { return }

                switch state {
                case .connected:
                    self.isConnected = true
                    self.isConnecting = false
                    self.reconnectAttempt = nil
                    self.connectionErrorMessage = nil
                    logger.info("GatewayClientWrapper observed connected")
                case .connecting:
                    self.isConnected = false
                    self.isConnecting = true
                    self.reconnectAttempt = nil
                    self.connectionErrorMessage = nil
                    logger.info("GatewayClientWrapper observed connecting")
                case .reconnecting(let attempt):
                    // Still "connecting" for gating purposes, but the attempt
                    // number travels with it so the UI can show a retry in
                    // progress rather than an indistinguishable first connect.
                    self.isConnected = false
                    self.isConnecting = true
                    self.reconnectAttempt = attempt
                    self.connectionErrorMessage = nil
                    logger.info("GatewayClientWrapper observed reconnecting attempt=\(attempt)")
                case .error(let message):
                    self.isConnected = false
                    self.isConnecting = false
                    self.reconnectAttempt = nil
                    self.connectionErrorMessage = message
                    self.connectTask = nil
                    logger.info("GatewayClientWrapper observed error=\(message)")
                case .disconnected:
                    self.isConnected = false
                    self.isConnecting = false
                    self.reconnectAttempt = nil
                    self.connectionErrorMessage = nil
                    self.connectTask = nil
                    logger.info("GatewayClientWrapper observed disconnected")
                }
            }
    }

    private func appendLog(_ text: String, error: Bool = false) {
        log.append(LogEntry(text: text, isError: error))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: - iOS Background Grace Period

    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Keep the WebSocket alive for the system-granted background grace
    /// period (~30s) so a short in-flight turn can stream to completion and
    /// post its completion notification before the socket is torn down.
    func beginBackgroundGracePeriod() {
        guard backgroundTaskID == .invalid else { return }
        // Capture the granted ID inside the expiration handler rather than
        // reading self.backgroundTaskID: if a new grace period starts before
        // the old one's expiration fires, the stale handler would otherwise
        // end the NEW task (wrong ID) and iOS kills apps that leak expired
        // background tasks.
        var grantedID: UIBackgroundTaskIdentifier = .invalid
        grantedID = UIApplication.shared.beginBackgroundTask(withName: "portal.finishTurn") { [weak self] in
            Task { @MainActor in
                guard let self else {
                    // Wrapper gone — still must end the task or iOS terminates us.
                    if grantedID != .invalid {
                        UIApplication.shared.endBackgroundTask(grantedID)
                    }
                    return
                }
                if self.backgroundTaskID == grantedID {
                    self.endBackgroundGracePeriod()
                } else if grantedID != .invalid {
                    // A newer grace period replaced us; end only OUR task.
                    UIApplication.shared.endBackgroundTask(grantedID)
                }
            }
        }
        backgroundTaskID = grantedID
        logger.info("began background grace period task=\(self.backgroundTaskID.rawValue)")
    }

    func endBackgroundGracePeriod() {
        guard backgroundTaskID != .invalid else { return }
        logger.info("ending background grace period task=\(self.backgroundTaskID.rawValue)")
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    #endif
}
