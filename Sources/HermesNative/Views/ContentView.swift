import SwiftUI

/// Root content view — NavigationSplitView with session sidebar + chat detail.
/// On macOS: real sidebar. On iPad: sidebar. On iPhone: compact push/pop.
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sessionList: SessionListViewModel
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        Group {
            if settings.isConfigured && gatewayClientWrapper.isConnected {
                sessionChatLayout
            } else {
                OnboardingView()
                    .environmentObject(gatewayClientWrapper)
            }
        }
        .task {
            if settings.isConfigured && (!settings.needsCFAuth || settings.cfAuthCookie != nil) {
                await gatewayClientWrapper.connect(using: settings)
                wireUpClient()
            }
        }
        .onChange(of: settings.isConfigured) { _, configured in
            if configured && (!settings.needsCFAuth || settings.cfAuthCookie != nil) {
                Task {
                    await gatewayClientWrapper.connect(using: settings)
                    wireUpClient()
                }
            }
        }
        .onChange(of: settings.cfAuthCookie) { _, cookie in
            if cookie != nil && settings.isConfigured {
                Task {
                    await gatewayClientWrapper.connect(using: settings)
                    wireUpClient()
                }
            }
        }
    }

    // MARK: - Session + Chat Layout

    private var sessionChatLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionListView()
                .environmentObject(sessionList)
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .navigationTitle("Sessions")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } detail: {
            ChatView()
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .id(chatViewModel.currentSessionID) // Re-create on session switch
        }
        #if os(macOS)
        .navigationSplitViewStyle(.balanced)
        #endif
        .onChange(of: sessionList.activeSessionID) { _, newID in
            guard let newID else { return }
            // If switching to a different session, resume it
            if newID != chatViewModel.currentSessionID,
               let session = sessionList.sessions.first(where: { $0.id == newID }) {
                Task {
                    do {
                        _ = try await sessionList.resumeSession(session)
                        await chatViewModel.resumeSession(key: session.key)
                    } catch {
                        chatViewModel.error = error.localizedDescription
                    }
                }
            }
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            // Sync session title to the sidebar when it changes
            guard let sid = chatViewModel.currentSessionID,
                  newTitle != oldTitle else { return }
            sessionList.updateSessionTitle(id: sid, title: newTitle)
        }
    }

    // MARK: - Wiring

    private func wireUpClient() {
        chatViewModel.setGatewayClient(gatewayClientWrapper.client)
        sessionList.setGatewayClient(gatewayClientWrapper.client)

        // Auto-create first session if none exists, then refresh list
        Task {
            await sessionList.refreshSessions()
            if sessionList.sessions.isEmpty {
                await chatViewModel.createSession()
                if let sid = chatViewModel.currentSessionID {
                    sessionList.selectSession(id: sid)
                    await sessionList.refreshSessions()
                }
            } else if let first = sessionList.sessions.first {
                // Resume first existing session
                sessionList.selectSession(id: first.id)
            }
        }
    }
}

// MARK: - Gateway Client Wrapper

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
