import SwiftUI
import Combine
import os
#if canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "com.researchoors.HermesNative", category: "GatewayClientWrapper")

/// Observable wrapper for the app-level GatewayClient lifecycle.
///
/// HermesNative uses one persistent WebSocket per app process. Sessions are
/// multiplexed over that socket by RPC/event `session_id`; creating/selecting a
/// session must not recreate the transport.
@MainActor
final class GatewayClientWrapper: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var isConnecting: Bool = false
    @Published var log: [LogEntry] = []
    /// Mirrors the current client's keepalive RTT so views observing the
    /// wrapper (not the inner client, which is swapped on reconnect) can
    /// show live latency.
    @Published private(set) var lastPingRTT: TimeInterval?
    private(set) var client: GatewayClient

    private var pingRTTCancellable: AnyCancellable?
    private var connectionCancellable: AnyCancellable?
    private var connectTask: Task<Void, Never>?
    private var currentSignature: ConnectionSignature?

    /// Lazily-created Centaur backend, keyed by (url, apiKey) so settings
    /// changes rebuild it. Independent of the WebSocket lifecycle above —
    /// Centaur is stateless REST until a session opens its SSE stream.
    private var centaurClient: CentaurClient?
    private var centaurSignature: String?

    /// Returns the Centaur backend for the current settings, or nil when
    /// Centaur mode is disabled or misconfigured.
    func centaurBackend(using settings: SettingsViewModel) -> CentaurClient? {
        guard settings.centaurEnabled, let url = settings.buildCentaurURL() else {
            centaurClient = nil
            centaurSignature = nil
            return nil
        }
        let signature = "\(url.absoluteString)|\(settings.centaurAPIKey)"
        if let existing = centaurClient, centaurSignature == signature {
            return existing
        }
        let client = CentaurClient(baseURL: url, apiKey: settings.centaurAPIKey)
        centaurClient = client
        centaurSignature = signature
        appendLog("Centaur backend: \(url.absoluteString)")
        return client
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
            appendLog("✗ Invalid gateway URL", error: true)
            isConnected = false
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

        if !force, currentSignature == signature {
            if isConnected { return true }
            if isConnecting || connectTask != nil {
                let connected = await waitUntilConnected(timeout: 12)
                logger.info("GatewayClientWrapper reused in-flight connection result=\(connected)")
                return connected
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
            let connected = await self?.waitUntilConnected(timeout: 12) ?? false
            guard !Task.isCancelled else { return }
            self?.isConnecting = false
            self?.connectTask = nil
            if !connected, newClient === self?.client {
                self?.appendLog("✗ Timed out waiting for WebSocket connection", error: true)
            }
        }

        let connected = await waitUntilConnected(timeout: 12)
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
            logger.info("connectWithRetry attempt \(attempt) failed; retrying in \(delay)s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return isConnected }
            if isConnected { return true }
            delay *= 2
        }
        return isConnected
    }

    func connectedClient(using settings: SettingsViewModel, timeout seconds: TimeInterval = 12) async -> GatewayClient? {
        guard await connectIfNeeded(using: settings) else { return nil }
        guard await waitUntilConnected(timeout: seconds) else { return nil }
        return client
    }

    /// Legacy name kept for callers that intentionally want to connect.
    func connect(using settings: SettingsViewModel) async {
        _ = await connectIfNeeded(using: settings)
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
                    logger.info("GatewayClientWrapper observed connected")
                case .connecting, .reconnecting:
                    self.isConnected = false
                    self.isConnecting = true
                    logger.info("GatewayClientWrapper observed connecting state=\(String(describing: state))")
                default:
                    self.isConnected = false
                    self.isConnecting = false
                    self.connectTask = nil
                    logger.info("GatewayClientWrapper observed non-connected state=\(String(describing: state))")
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
        grantedID = UIApplication.shared.beginBackgroundTask(withName: "hermes.finishTurn") { [weak self] in
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
