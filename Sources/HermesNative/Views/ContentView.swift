import SwiftUI

/// Root content view — TabView on iOS with "Sessions" + "Cron" tabs,
/// NavigationSplitView on macOS with a toolbar button for Cron sheet.
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @StateObject private var chatViewModel = ChatViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.scenePhase) private var scenePhase

    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var missionControlSessionID: String?
    @State private var observerSession: Session?
    @State private var showCronSheet = false
    @State private var showGatewayDebugSheet = false
    @State private var selectedTab = 0
    @State private var isCreatingSession = false
    @State private var sessionCreationError: String?
    @State private var wiredClient: GatewayClient?
    /// Suppresses selection-driven navigation/resume while New Session is already
    /// explicitly creating and pushing a chat. Without this, register/select can
    /// race the compact iOS NavigationStack and append the same destination twice.
    @State private var pendingCreatedSessionID: String?
    /// `ChatViewModel.createSession()` publishes `createGeneration` before
    /// `createAndSwitchToNewSession()` resumes. The explicit New Session flow does
    /// its own push afterward, so the observer must skip that intermediate push.
    @State private var shouldSuppressNextCreateGenerationPush = false
    #if os(iOS)
    @State private var iOSNavigationPath: [String] = []
    #endif

    var body: some View {
        Group {
            if settings.isConfigured {
                #if os(iOS)
                iosLayout
                #else
                macLayout
                #endif
            } else {
                OnboardingView()
                    .environmentObject(gatewayClientWrapper)
                    .environmentObject(chatViewModel)
            }
        }
        .task {
            if settings.isConfigured && (!settings.needsCFAuth || settings.cfAuthCookie != nil) {
                _ = await gatewayClientWrapper.connectIfNeeded(using: settings)
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

    // MARK: - iOS Layout (TabView)

    #if os(iOS)
    private var iosLayout: some View {
        TabView(selection: $selectedTab) {
            iOSSessionStack
                .tabItem {
                    Label("Sessions", systemImage: "bubble.left.and.bubble.right")
                }
                .tag(0)

            NavigationStack {
                CronListView()
                    .environmentObject(gatewayClientWrapper)
            }
            .tabItem {
                Label("Cron", systemImage: "clock.badge.checkmark")
            }
            .tag(1)
        }
    }

    private var iOSSessionStack: some View {
        NavigationStack(path: $iOSNavigationPath) {
            SessionListView(
                onMissionControl: { sessionID in
                    openMissionControl(sessionID: sessionID)
                },
                onCreateSession: {
                    Task { await createAndSwitchToNewSession() }
                },
                onOpenPanel: {
                    showCronSheet = true
                },
                onToggleSidebar: nil
            )
            .environmentObject(sessionList)
            .environmentObject(chatViewModel)
            .environmentObject(gatewayClientWrapper)
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                HStack {
                    EditButton()
                    Spacer()
                    Button("New Session") {
                        Task { await createAndSwitchToNewSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("newSessionButton")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .navigationDestination(for: String.self) { _ in
                ChatView()
                    .environmentObject(chatViewModel)
                    .environmentObject(gatewayClientWrapper)
                    .id(chatViewModel.currentSessionID)
            }
            .safeAreaInset(edge: .bottom) {
                sessionCreationStatusBar
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showGatewayDebugSheet = true
                    } label: {
                        Image(systemName: "wave.3.right.circle")
                    }
                    .accessibilityLabel("Gateway Debug")
                }
            }
            .onOpenURL { url in
                guard url.scheme == "hermesnative", url.host == "new-session" else { return }
                Task { await createAndSwitchToNewSession() }
            }
        }
        .onChange(of: sessionList.activeSessionID) { _, newID in
            handleSessionSelection(newID)
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            updateSelectedSessionTitle(oldTitle: oldTitle, newTitle: newTitle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesSwitchToSession)) { notification in
            switchToSession(from: notification)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: chatViewModel.currentSessionID) { _, newID in
            NotificationService.shared.activeSessionID = newID
        }
        .onChange(of: chatViewModel.createGeneration) { _, _ in
            guard let sid = chatViewModel.currentSessionID else { return }
            sessionList.registerOwnedSession(shortHexID: sid)
            if shouldSuppressNextCreateGenerationPush {
                shouldSuppressNextCreateGenerationPush = false
            } else {
                pushOwnedSessionOnIOS(sid)
            }
        }
        // Mission Control sheet (for owned sessions)
        .sheet(isPresented: Binding(
            get: { missionControlSessionID != nil },
            set: { if !$0 { missionControlSessionID = nil } }
        )) {
            if let sid = missionControlSessionID {
                SessionExplorerView(sessionID: sid)
                    .environmentObject(gatewayClientWrapper)
                    .environmentObject(spawnTreeStore)
                    .presentationDetents([.large])
            }
        }
        .onChange(of: iOSNavigationPath) { _, newPath in
            if newPath.isEmpty {
                sessionList.activeSessionID = nil
            }
        }
        .sheet(isPresented: $showCronSheet) {
            NavigationStack {
                CronListView()
                    .environmentObject(gatewayClientWrapper)
                    .presentationDetents([.large])
            }
        }
    }

    #endif

    // MARK: - macOS Layout (NavigationSplitView + Cron sheet)

    private var macLayout: some View {
        sessionChatLayout
            .sheet(isPresented: $showCronSheet) {
                NavigationStack {
                    CronListView()
                        .environmentObject(gatewayClientWrapper)
                        #if os(iOS)
                        .presentationDetents([.large])
                        #endif
                }
                .frame(minWidth: 500, minHeight: 400)
            }
            .sheet(isPresented: $showGatewayDebugSheet) {
                GatewayDebugPanelView(client: gatewayClientWrapper.client)
                    .frame(minWidth: 560, minHeight: 620)
            }
    }

    // MARK: - Session + Chat Layout

    private var sessionChatLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionListView(
                onMissionControl: { sessionID in
                    openMissionControl(sessionID: sessionID)
                },
                onCreateSession: {
                    Task { await createAndSwitchToNewSession() }
                },
                onOpenPanel: {
                    showCronSheet = true
                },
                onToggleSidebar: {
                    toggleSidebarColumn()
                }
            )
                .environmentObject(sessionList)
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .navigationTitle("")
                #if os(macOS)
                .toolbarBackground(.hidden, for: .windowToolbar)
                #endif
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        } detail: {
            ChatView()
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .id(chatViewModel.currentSessionID)
                #if os(macOS)
                .toolbarBackground(.hidden, for: .windowToolbar)
                #endif
        }
        #if os(macOS)
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .ignoresSafeArea(.container, edges: [.top, .bottom, .leading])
        #endif
        .onChange(of: sessionList.activeSessionID) { _, newID in
            handleSessionSelection(newID)
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            updateSelectedSessionTitle(oldTitle: oldTitle, newTitle: newTitle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesSwitchToSession)) { notification in
            switchToSession(from: notification)
        }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onChange(of: chatViewModel.currentSessionID) { _, newID in
            NotificationService.shared.activeSessionID = newID
        }
        .onChange(of: chatViewModel.createGeneration) { _, _ in
            guard let sid = chatViewModel.currentSessionID else { return }
            sessionList.registerOwnedSession(shortHexID: sid)
            if shouldSuppressNextCreateGenerationPush {
                shouldSuppressNextCreateGenerationPush = false
            } else {
                pushOwnedSessionOnIOS(sid)
            }
        }
        // Mission Control sheet (for owned sessions)
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
        // Observer sheet (for non-owned sessions)
        .sheet(item: $observerSession, onDismiss: {
            // Reset selection so re-clicking the same "Other Session"
            // fires onChange again. Re-select the active chat session.
            sessionList.activeSessionID = chatViewModel.currentSessionID
        }) { session in
            SessionObserverView(session: session)
                .environmentObject(gatewayClientWrapper)
                #if os(iOS)
                .presentationDetents([.large])
                #endif
        }
        .sheet(isPresented: $showGatewayDebugSheet) {
            GatewayDebugPanelView(client: gatewayClientWrapper.client)
                #if os(iOS)
                .presentationDetents([.large])
                #else
                .frame(minWidth: 560, minHeight: 620)
                #endif
        }
    }

    // MARK: - Session Selection

    private func toggleSidebarColumn() {
        #if os(macOS)
        withAnimation(.easeInOut(duration: 0.18)) {
            columnVisibility = (columnVisibility == .detailOnly) ? .automatic : .detailOnly
        }
        #endif
    }

    private func pushOwnedSessionOnIOS(_ sessionID: String) {
        #if os(iOS)
        if iOSNavigationPath.last != sessionID {
            NSLog("[HermesNative] push iOS session \(sessionID)")
            iOSNavigationPath.append(sessionID)
        }
        #endif
    }

    private func handleSessionSelection(_ newID: String?) {
        guard let newID else { return }
        // Find the session and use its database ID for resume.
        guard let session = sessionList.sessions.first(where: { $0.id == newID }) else { return }
        let rpcID = session.rpcID

        if session.isOwned {
            if pendingCreatedSessionID == newID || pendingCreatedSessionID == rpcID {
                pendingCreatedSessionID = nil
                return
            }

            pushOwnedSessionOnIOS(newID)

            if rpcID == chatViewModel.currentSessionID {
                spawnTreeStore.bindRuntimeSession(displayID: newID, runtimeID: rpcID)
                return
            }
            chatViewModel.loadLocalHistory(sessionID: newID)
            Task {
                // session.resume expects the database-format ID.
                await chatViewModel.resumeSession(key: newID)
                if let runtimeID = chatViewModel.currentSessionID {
                    spawnTreeStore.bindRuntimeSession(displayID: newID, runtimeID: runtimeID)
                }
            }
        } else {
            // Non-owned session — open observer view.
            observerSession = session
        }
    }

    @ViewBuilder
    private var sessionCreationStatusBar: some View {
        #if os(iOS)
        if isCreatingSession || sessionCreationError != nil || chatViewModel.error != nil {
            HStack(spacing: 8) {
                if isCreatingSession {
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                        .font(.caption)
                } else if let error = sessionCreationError ?? chatViewModel.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Retry") {
                        Task { await createAndSwitchToNewSession() }
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .foregroundStyle(Theme.primary)
            .accessibilityIdentifier("sessionCreationStatus")
        }
        #endif
    }

    @MainActor
    private func createAndSwitchToNewSession() async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        sessionCreationError = nil
        defer { isCreatingSession = false }

        guard let connectedClient = await gatewayClientWrapper.connectedClient(using: settings, timeout: 12) else {
            NSLog("[HermesNative] createAndSwitchToNewSession failed: gateway not connected")
            sessionCreationError = "Gateway is not connected"
            return
        }
        wireUpClient(connectedClient)

        NSLog("[HermesNative] createAndSwitchToNewSession starting session.create")
        shouldSuppressNextCreateGenerationPush = true
        await chatViewModel.createSession()

        if let error = chatViewModel.error {
            shouldSuppressNextCreateGenerationPush = false
            sessionCreationError = error
            return
        }

        guard let sid = chatViewModel.currentSessionID else {
            shouldSuppressNextCreateGenerationPush = false
            sessionCreationError = "Session create returned no session ID"
            return
        }

        pendingCreatedSessionID = sid
        sessionList.registerOwnedSession(shortHexID: sid)
        sessionList.selectSession(id: sid)
        spawnTreeStore.createTree(sessionID: sid)
        spawnTreeStore.bindRuntimeSession(displayID: sid, runtimeID: sid)
        pushOwnedSessionOnIOS(sid)
    }

    // MARK: - Mission Control

    private func openMissionControl(sessionID: String) {
        let session = sessionList.sessions.first(where: { $0.id == sessionID })
        let runtimeID = session?.rpcID ?? chatViewModel.currentSessionID ?? sessionID
        spawnTreeStore.createTree(sessionID: sessionID)
        spawnTreeStore.bindRuntimeSession(displayID: sessionID, runtimeID: runtimeID)
        spawnTreeStore.setActive(sessionID: sessionID)
        missionControlSessionID = sessionID
    }

    // MARK: - Wiring

    private func wireUpClient(_ client: GatewayClient? = nil) {
        let client = client ?? gatewayClientWrapper.client
        chatViewModel.setGatewayClient(client)
        sessionList.setGatewayClient(client)
        spawnTreeStore.subscribe(to: client)

        Task {
            await sessionList.refreshSessions()
            if chatViewModel.isSessionReady, let sid = chatViewModel.currentSessionID {
                if chatViewModel.messages.isEmpty {
                    chatViewModel.loadLocalHistory(sessionID: sid)
                }
                sessionList.selectSession(id: sid)
                spawnTreeStore.createTree(sessionID: sid)
                spawnTreeStore.bindRuntimeSession(displayID: sid, runtimeID: sid)
            }
        }
    }
    private func updateSelectedSessionTitle(oldTitle: String, newTitle: String) {
        guard let sid = chatViewModel.currentSessionID,
              newTitle != oldTitle else { return }
        sessionList.updateSessionTitle(id: sid, title: newTitle)
    }

    private func switchToSession(from notification: Notification) {
        if let sessionID = notification.userInfo?["session_id"] as? String {
            sessionList.selectSession(id: sessionID)
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase != .active {
            chatViewModel.saveHistory()
        }
        NotificationService.shared.isForegrounded = (newPhase == .active)
    }
}
