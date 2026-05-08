import SwiftUI
import Combine

/// Root content view — TabView on iOS with "Sessions" + "Cron" tabs,
/// custom split layout on macOS with app-owned chrome.
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var activityInbox = ActivityInboxViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @Environment(\.scenePhase) private var scenePhase

    @State private var isMacSidebarVisible = true
    private let macSidebarWidth: CGFloat = 352
    @State private var missionControlSessionID: String?
    @State private var missionControlRuntimeSessionID: String?
    @State private var observerSession: Session?
    @State private var showCronSheet = false
    @State private var showGatewayDebugSheet = false
    @State private var showActivitySheet = false
    @State private var selectedTab = 0
    @State private var isCreatingSession = false
    @State private var sessionCreationError: String?
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui
    @State private var wiredClient: GatewayClient?
    /// Suppresses selection-driven navigation/resume while New Session is already
    /// explicitly creating and pushing a chat. Without this, register/select can
    /// race the compact iOS NavigationStack and append the same destination twice.
    @State private var pendingCreatedSessionID: String?
    /// `ChatViewModel.createSession()` publishes `createGeneration` before
    /// `createAndSwitchToNewSession()` resumes. The explicit New Session flow does
    /// its own push afterward, so the observer must skip that intermediate push.
    @State private var shouldSuppressNextCreateGenerationPush = false
    @State private var chatRunStateCancellable: AnyCancellable?
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
                }
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
            handleSelectionChangeAfterViewUpdate(newID)
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            handleTitleChangeAfterViewUpdate(oldTitle: oldTitle, newTitle: newTitle)
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
            set: { if !$0 { missionControlSessionID = nil; missionControlRuntimeSessionID = nil } }
        )) {
            if let sid = missionControlSessionID {
                SessionExplorerView(sessionID: sid, runtimeSessionID: missionControlRuntimeSessionID)
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
        .sheet(isPresented: $showActivitySheet) {
            ActivityInboxView(viewModel: activityInbox, onOpenSession: { sessionID in
                showActivitySheet = false
                selectedTab = 0
                sessionList.selectSession(id: sessionID)
            })
            .presentationDetents([.large])
        }
    }

    #endif

    // MARK: - macOS Layout (custom split view + app-owned chrome)

    private var macLayout: some View {
        VStack(spacing: 0) {
            macTopChromeRow
            macSplitContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
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
        .sheet(isPresented: $showActivitySheet) {
            ActivityInboxView(viewModel: activityInbox, onOpenSession: { sessionID in
                showActivitySheet = false
                sessionList.selectSession(id: sessionID)
            })
            .frame(minWidth: 640, minHeight: 620)
        }
        .sheet(isPresented: Binding(
            get: { missionControlSessionID != nil },
            set: { if !$0 { missionControlSessionID = nil; missionControlRuntimeSessionID = nil } }
        )) {
            if let sid = missionControlSessionID {
                SessionExplorerView(sessionID: sid, runtimeSessionID: missionControlRuntimeSessionID)
                    .environmentObject(gatewayClientWrapper)
                    .environmentObject(spawnTreeStore)
            }
        }
        .sheet(item: $observerSession, onDismiss: {
            sessionList.activeSessionID = chatViewModel.currentSessionID
        }) { session in
            SessionObserverView(session: session)
                .environmentObject(gatewayClientWrapper)
        }
        .overlay(alignment: .topTrailing) {
            #if os(macOS)
            Button {
                showActivitySheet = true
            } label: {
                Label("Activity", systemImage: activityInbox.unreadCount > 0 ? "bell.badge.fill" : "bell")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.primary)
            .padding(.top, 10)
            .padding(.trailing, 14)
            .accessibilityLabel("Activity")
            .accessibilityIdentifier("activityInboxButton")
            #endif
        }
        .onChange(of: sessionList.activeSessionID) { _, newID in
            handleSelectionChangeAfterViewUpdate(newID)
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            handleTitleChangeAfterViewUpdate(oldTitle: oldTitle, newTitle: newTitle)
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
    }

    private var macTopChromeRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                // Standard traffic lights occupy the first ~78pt of the hidden
                // titlebar. Keep app controls out of that space.
                Color.clear.frame(width: 78)

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isMacSidebarVisible.toggle()
                    }
                } label: {
                    Image(systemName: isMacSidebarVisible ? "sidebar.left" : "sidebar.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Toggle Sidebar")
                .accessibilityIdentifier("sidebarToggleButton")

                Spacer(minLength: 0)
            }
            .frame(width: isMacSidebarVisible ? macSidebarWidth : 112, height: 40)
            .background(Theme.background)

            if isMacSidebarVisible {
                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1, height: 40)
            }

            chatToolbarPills
                .padding(.leading, 12)
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
                .background(Theme.background)
        }
        .frame(height: 40)
        .background(Theme.background)
    }

    private var chatToolbarPills: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                personaManager.activePersona.bubbleAvatar(size: 22)
                Text(personaManager.activePersona.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Circle()
                    .fill(chatViewModel.isStreaming ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())

            HStack(spacing: 4) {
                Image(systemName: activeSkin.icon)
                    .font(.caption2)
                Text(activeSkin.displayName)
                    .font(.caption2)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())

            Text(chatViewModel.currentModel.isEmpty ? "No model" : chatViewModel.currentModel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())

            if chatViewModel.isStreaming {
                Button {
                    Task { await chatViewModel.interrupt() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityIdentifier("stopButton")
            }
        }
        .frame(height: 40)
    }

    private var macSplitContent: some View {
        HStack(spacing: 0) {
            if isMacSidebarVisible {
                SessionListView(
                    onMissionControl: { sessionID in
                        openMissionControl(sessionID: sessionID)
                    },
                    onCreateSession: {
                        Task { await createAndSwitchToNewSession() }
                    },
                    onOpenPanel: {
                        showCronSheet = true
                    }
                )
                .environmentObject(sessionList)
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .frame(width: macSidebarWidth)
                .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(Theme.border)
                    .frame(width: 1)
            }

            ChatView()
                .environmentObject(chatViewModel)
                .environmentObject(gatewayClientWrapper)
                .environmentObject(capabilitiesStore)
                .id(chatViewModel.currentSessionID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Session Selection

    /// `List(selection:)` writes into `sessionList.activeSessionID` during
    /// SwiftUI's own view update pass. Resuming a chat synchronously from that
    /// `onChange` immediately publishes several observable values (`messages`,
    /// readiness, runtime session IDs), which triggers SwiftUI's
    /// “Publishing changes from within view updates” warning on macOS. Hop one
    /// main-actor turn before doing selection side effects so the list binding
    /// can finish its update transaction first.
    private func handleSelectionChangeAfterViewUpdate(_ newID: String?) {
        Task { @MainActor in
            await Task.yield()
            handleSessionSelection(newID)
        }
    }

    private func handleTitleChangeAfterViewUpdate(oldTitle: String, newTitle: String) {
        Task { @MainActor in
            await Task.yield()
            updateSelectedSessionTitle(oldTitle: oldTitle, newTitle: newTitle)
        }
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

            chatViewModel.bindRuntimeSession(displayID: newID, runtimeID: rpcID)
            spawnTreeStore.bindRuntimeSession(displayID: newID, runtimeID: rpcID)

            if rpcID == chatViewModel.currentSessionID {
                return
            }
            let generation = chatViewModel.beginSwitchToSession(key: newID)
            Task {
                // session.resume expects the database-format ID.
                let resumed = await chatViewModel.resumeSession(key: newID, generation: generation)
                guard resumed else { return }
                if let runtimeID = chatViewModel.currentSessionID {
                    chatViewModel.bindRuntimeSession(displayID: newID, runtimeID: runtimeID)
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
        sessionList.setRunState(.queued, for: sid)
        sessionList.selectSession(id: sid)
        chatViewModel.bindRuntimeSession(displayID: sid, runtimeID: sid)
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
        missionControlRuntimeSessionID = runtimeID
    }

    // MARK: - Wiring

    private func wireUpClient(_ client: GatewayClient? = nil) {
        let client = client ?? gatewayClientWrapper.client
        chatViewModel.setGatewayClient(client)
        sessionList.setGatewayClient(client)
        observeChatRunState()
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
    private func observeChatRunState() {
        guard chatRunStateCancellable == nil else { return }
        chatRunStateCancellable = chatViewModel.$isStreaming
            .receive(on: RunLoop.main)
            .sink { isStreaming in
                guard let sid = chatViewModel.currentSessionID else { return }
                if isStreaming {
                    sessionList.setRunState(.streaming, for: sid)
                } else if let existing = sessionList.runState(for: sid), existing != .failed && existing != .canceled {
                    sessionList.setRunState(.idle, for: sid)
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
