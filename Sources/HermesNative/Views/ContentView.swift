import SwiftUI

/// Root content view — NavigationSplitView with session sidebar + chat detail.
/// On macOS: real sidebar. On iPad: sidebar. On iPhone: compact push/pop.
/// Long-press a session row to open Mission Control (spawn tree explorer).
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()
    @Environment(\.scenePhase) private var scenePhase

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    /// Navigation path for the detail column (supports Mission Control push).
    @State private var detailPath = NavigationPath()

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
            SessionListView(onMissionControl: { sessionID in
                openMissionControl(sessionID: sessionID)
            })
                .environmentObject(sessionList)
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .navigationTitle("Sessions")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } detail: {
            NavigationStack(path: $detailPath) {
                ChatView()
                    .environmentObject(chatViewModel)
                    .environmentObject(gatewayClientWrapper)
                    .id(chatViewModel.currentSessionID)
                    .navigationDestination(for: MissionControlDestination.self) { dest in
                        SessionExplorerView(sessionID: dest.sessionID)
                            .environmentObject(gatewayClientWrapper)
                            .environmentObject(spawnTreeStore)
                    }
            }
        }
        #if os(macOS)
        .navigationSplitViewStyle(.balanced)
        #endif
        .onChange(of: sessionList.activeSessionID) { _, newID in
            guard let newID else { return }
            // Skip if already viewing this session
            guard newID != chatViewModel.currentSessionID else { return }

            // Pop back to chat when switching sessions
            detailPath.removeLast(detailPath.count)

            // Always load local history first (instant, no network needed)
            chatViewModel.loadLocalHistory(sessionID: newID)

            // Then try gateway resume if we have a key
            if let session = sessionList.sessions.first(where: { $0.id == newID }),
               let key = sessionList.keyForSession(id: newID) {
                Task {
                    do {
                        _ = try await sessionList.resumeSession(session)
                        await chatViewModel.resumeSession(key: key)
                    } catch {
                        // Gateway resume failed but local history is already loaded
                        // User can still see and read their past conversation
                    }
                }
            }
            // No key — can't resume on gateway, but local history is shown.
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            // Sync session title to the sidebar when it changes
            guard let sid = chatViewModel.currentSessionID,
                  newTitle != oldTitle else { return }
            sessionList.updateSessionTitle(id: sid, title: newTitle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesSwitchToSession)) { notification in
            // Notification tap — switch to the relevant session
            if let sessionID = notification.userInfo?["session_id"] as? String {
                sessionList.selectSession(id: sessionID)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Save chat history when app goes to background
            if newPhase != .active {
                chatViewModel.saveHistory()
            }
            // Update notification service foreground state
            NotificationService.shared.isForegrounded = (newPhase == .active)
        }
        .onChange(of: chatViewModel.currentSessionID) { _, newID in
            // Update notification service so it suppresses notifications for active session
            NotificationService.shared.activeSessionID = newID
        }
    }

    // MARK: - Mission Control Navigation

    private func openMissionControl(sessionID: String) {
        // Ensure the tree exists
        spawnTreeStore.createTree(sessionID: sessionID)
        // Push Mission Control onto the detail navigation stack
        detailPath.append(MissionControlDestination(sessionID: sessionID))
    }

    // MARK: - Wiring

    private func wireUpClient() {
        chatViewModel.setGatewayClient(gatewayClientWrapper.client)
        sessionList.setGatewayClient(gatewayClientWrapper.client)
        spawnTreeStore.subscribe(to: gatewayClientWrapper.client)

        // On startup: show local history immediately, then sync with gateway
        Task {
            await sessionList.refreshSessions()
            if sessionList.sessions.isEmpty && !chatViewModel.isSessionReady {
                // No sessions at all — create a fresh one
                await chatViewModel.createSession()
                if let sid = chatViewModel.currentSessionID {
                    if let key = gatewayClientWrapper.client.lastSessionKey {
                        sessionList.storeSessionKey(id: sid, key: key)
                    }
                    sessionList.selectSession(id: sid)
                    spawnTreeStore.createTree(sessionID: sid)
                    await sessionList.refreshSessions()
                }
            } else if chatViewModel.isSessionReady, let sid = chatViewModel.currentSessionID {
                // Already have a session — load local history if empty, then select
                if chatViewModel.messages.isEmpty {
                    chatViewModel.loadLocalHistory(sessionID: sid)
                }
                sessionList.selectSession(id: sid)
                spawnTreeStore.createTree(sessionID: sid)
            } else if let first = sessionList.sessions.first {
                // Load local history instantly for first session
                chatViewModel.loadLocalHistory(sessionID: first.id)
                sessionList.selectSession(id: first.id)
                spawnTreeStore.createTree(sessionID: first.id)
                // Then try gateway resume for the live connection
                if let key = sessionList.keyForSession(id: first.id) {
                    await chatViewModel.resumeSession(key: key)
                }
            }
        }
    }
}

/// Navigation destination type for pushing Mission Control into the detail column.
struct MissionControlDestination: Hashable {
    let sessionID: String
}
