import SwiftUI

/// Root content view — NavigationSplitView with session sidebar + chat detail.
/// Long-press a session row to open Mission Control (spawn tree explorer).
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()
    @Environment(\.scenePhase) private var scenePhase

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var missionControlSessionID: String?

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
            ChatView()
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .id(chatViewModel.currentSessionID)
        }
        #if os(macOS)
        .navigationSplitViewStyle(.balanced)
        #endif
        .onChange(of: sessionList.activeSessionID) { _, newID in
            guard let newID else { return }
            guard newID != chatViewModel.currentSessionID else { return }
            chatViewModel.loadLocalHistory(sessionID: newID)
            if let session = sessionList.sessions.first(where: { $0.id == newID }),
               let key = sessionList.keyForSession(id: newID) {
                Task {
                    do {
                        _ = try await sessionList.resumeSession(session)
                        await chatViewModel.resumeSession(key: key)
                    } catch {}
                }
            }
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            guard let sid = chatViewModel.currentSessionID,
                  newTitle != oldTitle else { return }
            sessionList.updateSessionTitle(id: sid, title: newTitle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesSwitchToSession)) { notification in
            if let sessionID = notification.userInfo?["session_id"] as? String {
                sessionList.selectSession(id: sessionID)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                chatViewModel.saveHistory()
            }
            NotificationService.shared.isForegrounded = (newPhase == .active)
        }
        .onChange(of: chatViewModel.currentSessionID) { _, newID in
            NotificationService.shared.activeSessionID = newID
        }
        // Mission Control — presented as sheet
        .sheet(isPresented: Binding(
            get: { missionControlSessionID != nil },
            set: { if !$0 { missionControlSessionID = nil } }
        )) {
            if let sid = missionControlSessionID {
                SessionExplorerView(sessionID: sid)
                    .environmentObject(gatewayClientWrapper)
                    .environmentObject(spawnTreeStore)
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
        }
    }

    // MARK: - Mission Control

    private func openMissionControl(sessionID: String) {
        spawnTreeStore.createTree(sessionID: sessionID)
        spawnTreeStore.setActive(sessionID: sessionID)
        missionControlSessionID = sessionID
    }

    // MARK: - Wiring

    private func wireUpClient() {
        chatViewModel.setGatewayClient(gatewayClientWrapper.client)
        sessionList.setGatewayClient(gatewayClientWrapper.client)
        spawnTreeStore.subscribe(to: gatewayClientWrapper.client)

        Task {
            await sessionList.refreshSessions()
            if sessionList.sessions.isEmpty && !chatViewModel.isSessionReady {
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
                if chatViewModel.messages.isEmpty {
                    chatViewModel.loadLocalHistory(sessionID: sid)
                }
                sessionList.selectSession(id: sid)
                spawnTreeStore.createTree(sessionID: sid)
            } else if let first = sessionList.sessions.first {
                chatViewModel.loadLocalHistory(sessionID: first.id)
                sessionList.selectSession(id: first.id)
                spawnTreeStore.createTree(sessionID: first.id)
                if let key = sessionList.keyForSession(id: first.id) {
                    await chatViewModel.resumeSession(key: key)
                }
            }
        }
    }
}
