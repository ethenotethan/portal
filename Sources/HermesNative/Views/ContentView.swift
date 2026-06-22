import SwiftUI
import Combine
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ContentView")

/// Root content view — TabView on iOS with "Sessions" + "Cron" tabs,
/// custom split layout on macOS with app-owned chrome.
struct ContentView: View {
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var sessionList: SessionListViewModel
    @EnvironmentObject var spawnTreeStore: SpawnTreeStore
    @EnvironmentObject var celebrationManager: CelebrationManager
    @EnvironmentObject var ttsService: TTSService
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore
    @StateObject private var chatViewModel = ChatViewModel()
    @StateObject private var activityInbox = ActivityInboxViewModel()
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @ObservedObject private var cronRunStore = CronRunHistoryStore.shared
    @StateObject private var cronPoller = CronPoller()
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSettings = false
    @State private var isMacSidebarVisible = true
    private let macSidebarWidth: CGFloat = 352
    @State private var missionControlSessionID: String?
    @State private var missionControlRuntimeSessionID: String?
    @State private var observerSession: Session?
    @State private var isObserverDismissing = false
    @State private var previousActiveSessionID: String?  // Preserve List selection when opening observer
    @State private var showCronSheet = false
    @State private var showGatewayDebugSheet = false
    @State private var showActivitySheet = false
    @State private var showLiveSessions = false
    @State private var showCronDashboard = false
    @State private var showSkills = false
    @State private var showWikiGraph = false
    @State private var showFeedSheet = false
    @State private var showLearning = false
    @State private var selectedTab = 0
    @State private var isCreatingSession = false
    @State private var sessionCreationError: String?
    @State private var lastProcessedSelectionID: String?
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

            // Celebration overlay — positive reinforcement effects
            if celebrationManager.activeCelebration != nil {
                CelebrationOverlay(
                    particles: ConfettiParticle.burst(count: 60),
                    onComplete: { celebrationManager.activeCelebration = nil }
                )
            }
        }
        .task {
            if settings.isConfigured {
                // Bounded retry: a cold-start connect can fail before the
                // network path is up, and a failed first connect is terminal
                // (GatewayClient only auto-reconnects after a successful
                // connection). Without the retry the app sits disconnected
                // until the user taps something that reconnects.
                await gatewayClientWrapper.connectWithRetry(using: settings)
                wireUpClient()
                if gatewayClientWrapper.isConnected {
                    await sessionList.refreshSessions()
                }
            }
        }
        .onChange(of: gatewayClientWrapper.isConnected) { _, connected in
            if connected {
                Task { await sessionList.refreshSessions() }
            }
        }
        .onChange(of: settings.isConfigured) { _, configured in
            if configured {
                Task {
                    await gatewayClientWrapper.connectWithRetry(using: settings)
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

            WikiGraphView()
                .environmentObject(gatewayClientWrapper)
                .tabItem {
                    Label("Wiki", systemImage: "network")
                }
                .tag(2)

            SkillsView()
                .environmentObject(gatewayClientWrapper)
                .tabItem {
                    Label("Skills", systemImage: "sparkles")
                }
                .tag(3)

            NavigationStack {
                FeedView()
                    .environmentObject(gatewayClientWrapper)
            }
            .tabItem {
                Label("Feed", systemImage: "newspaper")
            }
            .tag(4)

            LearningDashboardView(
                onClose: { },
                onStudyDeck: { _ in },
                onRetakeQuiz: { _, _ in }
            )
            .tabItem {
                Label("Learning", systemImage: "books.vertical.fill")
            }
            .tag(5)
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLiveSessions = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .accessibilityLabel("Sessions")
                }
            }
            .onOpenURL { url in
                handleDeepLink(url)
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
        .onReceive(NotificationCenter.default.publisher(for: .hermesOpenDeepLink)) { notification in
            if let urlString = notification.userInfo?["url"] as? String,
               let url = URL(string: urlString) {
                handleDeepLink(url)
            }
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
                    .environmentObject(sessionList)
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
        .onChange(of: showCronSheet) { _, presented in
            if presented { cronRunStore.markAllCronRunsRead() }
        }
        .sheet(isPresented: $showActivitySheet) {
            ActivityInboxView(viewModel: activityInbox, onOpenSession: { sessionID in
                showActivitySheet = false
                selectedTab = 0
                sessionList.selectSession(id: sessionID)
            })
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showLiveSessions) {
            SessionsDashboard(onOpenSession: { sessionID in
                openMissionControl(sessionID: sessionID)
            })
                .environmentObject(sessionList)
                .environmentObject(gatewayClientWrapper)
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
        .onOpenURL { url in
            handleDeepLink(url)
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
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(personaManager)
                .environmentObject(capabilitiesStore)
                .frame(minWidth: 500, minHeight: 450)
        }
        .sheet(item: $observerSession, onDismiss: {
            isObserverDismissing = true
            let prev = previousActiveSessionID
            previousActiveSessionID = nil
            if let prev {
                sessionList.activeSessionID = prev
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isObserverDismissing = false
            }
        }, content: { session in
            SessionObserverView(session: session)
                .environmentObject(gatewayClientWrapper)
        })
        .onChange(of: sessionList.activeSessionID) { _, newID in
            handleSelectionChangeAfterViewUpdate(newID)
        }
        .onChange(of: chatViewModel.sessionTitle) { oldTitle, newTitle in
            handleTitleChangeAfterViewUpdate(oldTitle: oldTitle, newTitle: newTitle)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesSwitchToSession)) { notification in
            switchToSession(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: .hermesOpenDeepLink)) { notification in
            if let urlString = notification.userInfo?["url"] as? String,
               let url = URL(string: urlString) {
                handleDeepLink(url)
            }
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

    private var isOverlayActive: Bool {
        missionControlSessionID != nil || showCronDashboard || showLiveSessions || showActivitySheet || showFeedSheet || showSkills || showWikiGraph || showLearning
    }

    private var overlayTitle: String {
        if showWikiGraph { return "Wiki Graph" }
        if showFeedSheet { return "Feed" }
        if showSkills { return "Skills" }
        if showLiveSessions { return "Sessions" }
        if showCronDashboard { return "Cron Activity" }
        if showActivitySheet { return "Activity" }
        if showLearning { return "Learning" }
        if missionControlSessionID != nil { return "Mission Control" }
        return ""
    }

    private var macTopChromeRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
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

            if isOverlayActive {
                overlayHeaderBar
            } else {
                HStack(spacing: 0) {
                    chatToolbarPills
                        .padding(.leading, 12)
                    Spacer(minLength: 0)
                    #if os(macOS)
                    macOverlayIcons
                        .padding(.trailing, 14)
                    #endif
                }
                .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
                .background(Theme.background)
            }
        }
        .frame(height: 40)
        .background(Theme.background)
    }

    private var overlayHeaderBar: some View {
        HStack(spacing: 12) {
            Button {
                missionControlSessionID = nil
                missionControlRuntimeSessionID = nil
                showCronDashboard = false
                showLiveSessions = false
                showActivitySheet = false
                showSkills = false
                showWikiGraph = false
                showFeedSheet = false
                showLearning = false
                chatViewModel.refocusInput += 1
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])

            Text(overlayTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primary)

            Spacer(minLength: 0)

            #if os(macOS)
            macOverlayIcons
            #endif
        }
        .padding(.leading, 12)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
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

    #if os(macOS)
    private var macOverlayIcons: some View {
        HStack(spacing: 8) {
            Button {
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: .command)
            .accessibilityLabel("Settings")

            Button {
                showLiveSessions = true
            } label: {
                Label("Sessions", systemImage: "square.grid.2x2")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("l", modifiers: .command)
            .accessibilityLabel("Sessions")

            Button {
                showCronDashboard = true
                CronRunHistoryStore.shared.markAllCronRunsRead()
            } label: {
                Label("Cron", systemImage: "clock.badge.checkmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .overlay(alignment: .topTrailing) {
                if cronRunStore.unreadCronRunCount > 0 {
                    Text("\(cronRunStore.unreadCronRunCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Circle().fill(.red))
                        .offset(x: 6, y: -4)
                }
            }
            .keyboardShortcut("k", modifiers: .command)
            .accessibilityLabel("Cron Dashboard")

            Button {
                showActivitySheet = true
            } label: {
                Label("Activity", systemImage: activityInbox.unreadCount > 0 ? "bell.badge.fill" : "bell")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.primary)
            .accessibilityLabel("Activity")
            .accessibilityIdentifier("activityInboxButton")

            Button {
                showSkills = true
            } label: {
                Label("Skills", systemImage: "sparkles")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("j", modifiers: .command)
            .accessibilityLabel("Skills")

            Button {
                showFeedSheet = true
            } label: {
                Label("Feed", systemImage: "newspaper")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityLabel("Feed")

            Button {
                showLearning = true
            } label: {
                Label("Learning", systemImage: "books.vertical.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("e", modifiers: .command)
            .accessibilityLabel("Learning")

            Button {
                showWikiGraph = true
            } label: {
                Label("Wiki", systemImage: "network")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("w", modifiers: .command)
            .accessibilityLabel("Wiki Graph")
        }
        .foregroundStyle(Theme.primary)
    }
    #endif

    private var macSplitContent: some View {
        ZStack {
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
                            showCronDashboard = true
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

            if let sid = missionControlSessionID {
                SessionExplorerView(sessionID: sid, runtimeSessionID: missionControlRuntimeSessionID, onDismiss: {
                    missionControlSessionID = nil
                    missionControlRuntimeSessionID = nil
                    chatViewModel.refocusInput += 1
                })
                    .environmentObject(gatewayClientWrapper)
                    .environmentObject(spawnTreeStore)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .transition(.opacity)
            }

            if showLiveSessions {
                SessionsDashboard(onOpenSession: { sessionID in
                    showLiveSessions = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        openMissionControl(sessionID: sessionID)
                    }
                })
                    .environmentObject(sessionList)
                    .environmentObject(gatewayClientWrapper)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .transition(.opacity)
            }

            if showCronDashboard {
                CronDashboardView()
                    .environmentObject(gatewayClientWrapper)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .transition(.opacity)
            }

            if showSkills {
                SkillsView()
                    .environmentObject(gatewayClientWrapper)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .transition(.opacity)
            }

            if showFeedSheet {
                FeedView()
                    .environmentObject(gatewayClientWrapper)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .transition(.opacity)
            }

            if showLearning {
                LearningDashboardView(
                    onClose: {
                        showLearning = false
                        chatViewModel.refocusInput += 1
                    },
                    onStudyDeck: { deck in
                        showLearning = false
                        chatViewModel.refocusInput += 1
                        NotificationCenter.default.post(
                            name: .hermesStudyDeck,
                            object: nil,
                            userInfo: ["deck": deck]
                        )
                    },
                    onRetakeQuiz: { questions, topic in
                        showLearning = false
                        chatViewModel.refocusInput += 1
                        NotificationCenter.default.post(
                            name: .hermesRetakeQuiz,
                            object: nil,
                            userInfo: ["questions": questions, "topic": topic]
                        )
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .transition(.opacity)
            }

            if showWikiGraph {
                WikiGraphView()
                    .environmentObject(gatewayClientWrapper)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
                    .transition(.opacity)
            }
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
        guard observerSession == nil, !isObserverDismissing else { return }
        guard newID != lastProcessedSelectionID else { return }
        if sessionList.isSuppressingSelectionHandler {
            sessionList.isSuppressingSelectionHandler = false
            return
        }
        lastProcessedSelectionID = newID
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
            log.info("push iOS session \(sessionID)")
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
            previousActiveSessionID = nil

            // Don't resume the session we just finished creating — the sentinel
            // is set before createSession and stays set until the user clicks a
            // different session, so all activeSessionID changes during creation
            // (including the title-discovery dbID flip) are silently ignored.
            if pendingCreatedSessionID == newID || pendingCreatedSessionID == rpcID || pendingCreatedSessionID == "__creating__" {
                return
            }
            pendingCreatedSessionID = nil

            pushOwnedSessionOnIOS(newID)

            chatViewModel.bindRuntimeSession(displayID: newID, runtimeID: rpcID)
            spawnTreeStore.bindRuntimeSession(displayID: newID, runtimeID: rpcID)

            if rpcID == chatViewModel.currentSessionID {
                return
            }
            let generation = chatViewModel.beginSwitchToSession(key: newID)
            chatViewModel.refocusInput += 1
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
            // Non-owned session — defer sheet presentation completely outside
            // the current run loop to avoid AppKit layout recursion.
            let sessionToObserve = session
            let ownedSessionID = chatViewModel.currentSessionID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.previousActiveSessionID = ownedSessionID
                self.observerSession = sessionToObserve
            }
        }
    }

    @ViewBuilder
    private var sessionCreationStatusBar: some View {
        #if os(iOS)
        if isCreatingSession || sessionCreationError != nil || chatViewModel.error != nil {
            HStack(spacing: 8) {
                if isCreatingSession {
                    HermesProgressView()
                        .scaleEffect(0.7)
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
            log.error("createAndSwitchToNewSession failed: gateway not connected")
            sessionCreationError = "Gateway is not connected"
            return
        }
        wireUpClient(connectedClient)

        log.info("createAndSwitchToNewSession starting session.create")
        shouldSuppressNextCreateGenerationPush = true
        pendingCreatedSessionID = "__creating__"
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
        activityInbox.setGatewayClient(client)
        SkillStore.shared.setGatewayClient(client)
        observeChatRunState()
spawnTreeStore.subscribe(to: client)
        cronPoller.setGatewayClient(client)
    }

    private func observeChatRunState() {
        guard chatRunStateCancellable == nil else { return }
        chatRunStateCancellable = chatViewModel.$isStreaming
            .receive(on: RunLoop.main)
            .sink { isStreaming in
                #if os(iOS)
                // Turn finished while we were holding the background grace
                // period — release the assertion early.
                if !isStreaming {
                    gatewayClientWrapper.endBackgroundGracePeriod()
                }
                #endif
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

    /// Dispatch `hermesnative://` URLs to the right in-app action. Both
    /// platforms attach this to their root view via `.onOpenURL`. The URL
    /// scheme is registered in HermesNative-{macOS,iOS}/Info.plist; see
    /// `HermesNativeDeepLink` for the canonical URL grammar.
    private func handleDeepLink(_ url: URL) {
        guard let link = HermesNativeDeepLink(url: url) else {
            log.debug("handleDeepLink: ignoring unrecognised URL \(url.absoluteString)")
            return
        }
        switch link {
        case .newSession:
            Task { await createAndSwitchToNewSession() }
        case .session(let id):
            log.info("handleDeepLink: switching to session \(id)")
            sessionList.selectSession(id: id)
        case .activity:
            showActivitySheet = true
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase != .active {
            chatViewModel.saveHistory()
            #if os(iOS)
            // If a turn is streaming, ask iOS for the short background grace
            // period (~30s) so the socket stays up long enough for quick turns
            // to finish and post their completion notification.
            if newPhase == .background, chatViewModel.isStreaming {
                gatewayClientWrapper.beginBackgroundGracePeriod()
            }
            #endif
        } else {
            #if os(iOS)
            gatewayClientWrapper.endBackgroundGracePeriod()
            #endif
            if settings.isConfigured {
                Task {
                    if !gatewayClientWrapper.isConnected, !gatewayClientWrapper.isConnecting {
                        await gatewayClientWrapper.connectWithRetry(using: settings)
                        wireUpClient()
                    } else if gatewayClientWrapper.isConnecting {
                        _ = await gatewayClientWrapper.waitUntilConnected(timeout: 12)
                    }
                    #if os(iOS)
                    // Sessions ran server-side while we were suspended; the
                    // launch task's refresh never re-runs, so resync here or
                    // the UI shows stale progress until the user pokes it.
                    guard gatewayClientWrapper.isConnected else { return }
                    await sessionList.refreshSessions()
                    await resyncActiveChatSession()
                    #endif
                }
            }
        }
        NotificationService.shared.isForegrounded = (newPhase == .active)
    }

    #if os(iOS)
    /// Re-attach the open chat to its server-side session after returning to
    /// the foreground. `session.resume` returns the persisted history, so a
    /// turn that progressed or completed while suspended becomes visible
    /// without manual poking. ChatViewModel's own streaming-state guards keep
    /// a genuinely live turn from being clobbered by stale history.
    private func resyncActiveChatSession() async {
        guard let activeID = sessionList.activeSessionID,
              let session = sessionList.sessions.first(where: { $0.id == activeID }),
              session.isOwned else { return }
        await chatViewModel.resumeSession(key: activeID)
    }
    #endif
}
