import SwiftUI

/// Root tab view — Mission Control (navigation) and Chat (conversation).
struct AppTabView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @EnvironmentObject var sessionList: SessionListViewModel
    @StateObject private var chatViewModel = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: AppTab = .missionControl

    enum AppTab: Hashable {
        case missionControl
        case chat
    }

    var body: some View {
        Group {
            if settings.isConfigured && gatewayClientWrapper.isConnected {
                tabContent
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

    // MARK: - Tab Content

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            // Mission Control tab
            MissionControlView()
                .environmentObject(sessionList)
                .environmentObject(spawnTreeStore)
                .environmentObject(gatewayClientWrapper)
                .tabItem {
                    Label("Mission Control", systemImage: "network")
                }
                .tag(AppTab.missionControl)

            // Chat tab
            NavigationSplitView {
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
                    .id(chatViewModel.currentSessionID)
            }
            #if os(macOS)
            .navigationSplitViewStyle(.balanced)
            #endif
            .tabItem {
                Label("Chat", systemImage: "bubble.left.and.bubble.right")
            }
            .tag(AppTab.chat)
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
                spawnTreeStore.setActive(sessionID: sid)
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
