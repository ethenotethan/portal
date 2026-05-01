import SwiftUI
import Combine

/// Observable wrapper for the GatewayClient lifecycle.
@MainActor
final class GatewayClientWrapper: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var log: [LogEntry] = []
    private(set) var client: GatewayClient

    struct LogEntry: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    init() {
        self.client = GatewayClient()
    }

    func connect(using settings: SettingsViewModel) async {
        client.disconnect()
        log.removeAll()

        guard let newClient = settings.makeGatewayClient() else {
            appendLog("✗ Invalid gateway URL", error: true)
            isConnected = false
            return
        }

        appendLog("URL: \(settings.buildWebSocketURL()?.absoluteString ?? "nil")")
        appendLog("API key: \(settings.apiKey.isEmpty ? "none" : "set (\(settings.apiKey.prefix(8))…)")")
        appendLog("CF Access: \(settings.cfAuthCookie != nil ? "authenticated" : "not set")")

        client = newClient
        client.$connectionState
            .map { state -> Bool in
                if case .connected = state { return true }
                return false
            }
            .assign(to: &$isConnected)

        client.onLog = { [weak self] message, isError in
            Task { @MainActor in
                self?.appendLog(message, error: isError)
            }
        }

        client.connect()
    }

    private func appendLog(_ text: String, error: Bool = false) {
        log.append(LogEntry(text: text, isError: error))
    }
}
