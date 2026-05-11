import SwiftUI
import Combine
import os

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
    private(set) var client: GatewayClient

    private var connectionCancellable: AnyCancellable?
    private var connectTask: Task<Void, Never>?
    private var currentSignature: ConnectionSignature?

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
}
