import SwiftUI

/// Root content view — switches between onboarding and chat.
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            Group {
                if settings.isConfigured && gatewayClientWrapper.isConnected {
                    ChatView()
                        .environmentObject(chatViewModel)
                        .environmentObject(gatewayClientWrapper)
                } else {
                    OnboardingView()
                        .environmentObject(gatewayClientWrapper)
                }
            }
            .frame(maxHeight: .infinity)

            // Connection log bar — pinned below, not overlaying
            if settings.isConfigured && !gatewayClientWrapper.isConnected {
                connectionStatusBar
            }
        }
        .task {
            // Only auto-connect if CF Access is not needed or already authenticated
            if settings.isConfigured && (!settings.needsCFAuth || settings.cfAuthCookie != nil) {
                await gatewayClientWrapper.connect(using: settings)
                chatViewModel.setGatewayClient(gatewayClientWrapper.client)
            }
        }
        .onChange(of: settings.isConfigured) { _, configured in
            if configured && (!settings.needsCFAuth || settings.cfAuthCookie != nil) {
                Task {
                    await gatewayClientWrapper.connect(using: settings)
                    chatViewModel.setGatewayClient(gatewayClientWrapper.client)
                }
            }
        }
        .onChange(of: settings.cfAuthCookie) { _, cookie in
            // Auto-reconnect when CF Access cookie becomes available
            if cookie != nil && settings.isConfigured {
                Task {
                    await gatewayClientWrapper.connect(using: settings)
                    chatViewModel.setGatewayClient(gatewayClientWrapper.client)
                }
            }
        }
    }

    private var connectionStatusBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                switch gatewayClientWrapper.client.connectionState {
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                case .connected:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Connected")
                case .error(let msg):
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text("Error: \(msg)")
                case .disconnected:
                    Image(systemName: "circle").foregroundStyle(.secondary)
                    Text("Disconnected")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            // Connection log
            if !gatewayClientWrapper.log.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(gatewayClientWrapper.log) { entry in
                                Text(entry.text)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(entry.isError ? .red : .secondary)
                                    .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: gatewayClientWrapper.log.count) { _, _ in
                        if let last = gatewayClientWrapper.log.last {
                            proxy.scrollTo(last.id)
                        }
                    }
                }
            }
        }
        .padding()
    }
}

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
