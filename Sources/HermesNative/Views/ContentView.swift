import SwiftUI

/// Root content view — NavigationSplitView with session sidebar + chat detail.
/// My Sessions: tap to chat, long-press for Mission Control.
/// Other Sessions: tap to open read-only observer view.
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()
    @Environment(\.scenePhase) private var scenePhase

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var missionControlSessionID: String?
    @State private var observerSession: Session?

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
            if configured && (!settings.needsCFAuth || settings.cfAuthCookie == nil) {
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
            SessionListView(
                onMissionControl: { sessionID in
                    openMissionControl(sessionID: sessionID)
                },
                onObserve: { sessionID in
                    // Find the session object for the observer
                    observerSession = sessionList.sessions.first(where: { $0.id == sessionID })
                }
            )
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
            // Find the session and use its database ID for resume
            guard let session = sessionList.sessions.first(where: { $0.id == newID }) else { return }
            let rpcID = session.rpcID
            guard rpcID != chatViewModel.currentSessionID else { return }
            chatViewModel.loadLocalHistory(sessionID: newID)
            if session.isOwned {
                Task {
                    do {
                        // session.resume expects the database-format ID
                        _ = try await chatViewModel.resumeSession(key: newID)
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
        // Mission Control sheet (for owned sessions)
        .sheet(isPresented: Binding(
            get: { missionControlSessionID != nil },
            set: { if !$0 { missionControlSessionID = nil } }
        )) {
            if let sid = missionControlSessionID {
                // Use the gatewayID (short hex) for Mission Control if available
                let rpcID = sessionList.sessions.first(where: { $0.id == sid })?.rpcID ?? sid
                SessionExplorerView(sessionID: rpcID)
                    .environmentObject(gatewayClientWrapper)
                    .environmentObject(spawnTreeStore)
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
        }
        // Observer sheet (for non-owned sessions)
        .sheet(item: $observerSession) { session in
            SessionObserverView(session: session)
                .environmentObject(gatewayClientWrapper)
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
    }

    // MARK: - Mission Control

    private func openMissionControl(sessionID: String) {
        let rpcID = sessionList.sessions.first(where: { $0.id == sessionID })?.rpcID ?? sessionID
        spawnTreeStore.createTree(sessionID: rpcID)
        spawnTreeStore.setActive(sessionID: rpcID)
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
                    sessionList.registerOwnedSession(shortHexID: sid)
                    spawnTreeStore.createTree(sessionID: sid)
                }
            } else if chatViewModel.isSessionReady, let sid = chatViewModel.currentSessionID {
                if chatViewModel.messages.isEmpty {
                    chatViewModel.loadLocalHistory(sessionID: sid)
                }
                sessionList.selectSession(id: sid)
                spawnTreeStore.createTree(sessionID: sid)
            } else if let first = sessionList.sessions.first(where: { $0.isOwned }) ?? sessionList.sessions.first {
                chatViewModel.loadLocalHistory(sessionID: first.id)
                sessionList.selectSession(id: first.id)
                spawnTreeStore.createTree(sessionID: first.rpcID)
                if first.isOwned {
                    await chatViewModel.resumeSession(key: first.id)
                }
            }
        }
    }
}
