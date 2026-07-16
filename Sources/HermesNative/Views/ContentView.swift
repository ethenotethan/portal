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
    @State private var showAddGateway = false
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
                // Register this device's APNs token with whichever gateway we
                // just connected to (no-op until the OS grants a token, and
                // once per gateway+token thereafter).
                PushRegistrationService.shared.syncIfNeeded(
                    client: gatewayClientWrapper.client,
                    gatewayURL: settings.gatewayURL
                )
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
        .onChange(of: settings.activeGatewayID) { oldID, newID in
            // User switched gateways: tear down all in-memory state tied to the
            // previous gateway, reconnect the shared client to the new one, and
            // repopulate. Guard against the initial nil→value resolution at
            // launch (no actual switch).
            guard oldID != nil, newID != nil, settings.isConfigured else { return }
            handleGatewaySwitch()
        }
        .onReceive(PushRegistrationService.shared.$deviceTokenHex) { token in
            // The OS usually grants the APNs token AFTER the first connect
            // completes — re-sync when it lands so cold launch registers too.
            guard token != nil, gatewayClientWrapper.isConnected else { return }
            PushRegistrationService.shared.syncIfNeeded(
                client: gatewayClientWrapper.client,
                gatewayURL: settings.gatewayURL
            )
        }
    }

    /// Reset state and reconnect after the active gateway changes.
    @MainActor
    private func handleGatewaySwitch() {
        log.info("handleGatewaySwitch: switching to \(settings.gatewayURL)")
        // Drop all conversation/session state belonging to the old gateway.
        chatViewModel.saveHistory()
        chatViewModel.resetForGatewaySwitch()
        sessionList.resetForGatewaySwitch()
        activityInbox.clearAll()

        Task {
            // force: the URL/key changed, so the existing signature check must
            // be bypassed to actually recreate the transport.
            await gatewayClientWrapper.connectWithRetry(using: settings)
            wireUpClient()
            if gatewayClientWrapper.isConnected {
                await sessionList.refreshSessions()
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

            LearningDashboardView(onClose: { })
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
                onCreateSessionOnBackend: { entry in
                    Task { await createAndSwitchToNewSession(on: entry) }
                },
                sessionScopedBackends: settings.sessionScopedBackends,
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
                    newSessionControl
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
        .sheet(isPresented: $showAddGateway) {
            // AddGatewaySheet is macOS-only (the toolbar switcher that
            // presents it is too); give iOS an inert branch so the shared
            // modifier chain compiles on both platforms.
            #if os(macOS)
            AddGatewaySheet { name, url, key, kind in
                settings.addGateway(name: name, url: url, apiKey: key, kind: kind)
                showAddGateway = false
            } onCancel: {
                showAddGateway = false
            }
            #else
            EmptyView()
            #endif
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


    /// Identity the chat chrome presents — harness-fixed for session-scoped
    /// backends (Centaur), persona-driven for Hermes.
    private var displayPersona: Persona {
        chatViewModel.backendCapabilities.harnessPersona ?? personaManager.activePersona
    }

    private var chatToolbarPills: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                displayPersona.bubbleAvatar(size: 22)
                Text(displayPersona.name)
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

            ModelPickerMenu()
                .environmentObject(chatViewModel)

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
    @ViewBuilder
    private var gatewaySwitcher: some View {
        // Always visible (even with a single saved gateway) so adding a second
        // gateway is discoverable from the toolbar, not buried in Settings.
        Menu {
            ForEach(settings.savedGateways) { gateway in
                Button {
                    settings.selectGateway(gateway)
                } label: {
                    if settings.isActive(gateway) {
                        Label(gateway.displayName, systemImage: "checkmark")
                    } else {
                        Text(gateway.displayName)
                    }
                }
            }
            if !settings.savedGateways.isEmpty {
                Divider()
            }
            if !gatewayClientWrapper.isConnected && !gatewayClientWrapper.isConnecting {
                Button("Reconnect") {
                    Task {
                        await gatewayClientWrapper.connectWithRetry(using: settings)
                        wireUpClient()
                    }
                }
            }
            Button("Add Gateway…") { showAddGateway = true }
            Button("Manage Gateways…") { showSettings = true }
        } label: {
            HStack(spacing: 5) {
                gatewayHealthDot
                Image(systemName: "server.rack")
                    .font(.caption)
                Text(activeGatewayLabel)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(gatewayHealthHelp)
        .accessibilityIdentifier("gatewaySwitcher")
    }

    /// Health dot: green = connected (pulsing amber if RTT is degraded),
    /// amber = connecting, red = disconnected.
    private var gatewayHealthDot: some View {
        Circle()
            .fill(gatewayHealthColor)
            .frame(width: 7, height: 7)
    }

    private var gatewayHealthColor: Color {
        if gatewayClientWrapper.isConnected {
            // Degraded when the keepalive RTT crosses 750ms.
            if let rtt = gatewayClientWrapper.lastPingRTT, rtt > 0.75 {
                return .yellow
            }
            return .green
        }
        return gatewayClientWrapper.isConnecting ? .yellow : .red
    }

    private var gatewayHealthHelp: String {
        if gatewayClientWrapper.isConnected {
            if let rtt = gatewayClientWrapper.lastPingRTT {
                return String(format: "Connected — %.0fms round-trip. Click to switch gateway.", rtt * 1000)
            }
            return "Connected. Click to switch gateway."
        }
        if gatewayClientWrapper.isConnecting {
            return "Connecting…"
        }
        return "Disconnected — open the menu to reconnect or switch gateway."
    }

    private var activeGatewayLabel: String {
        settings.savedGateways.first { settings.isActive($0) }?.displayName ?? "Gateway"
    }

    private var macOverlayIcons: some View {
        HStack(spacing: 8) {
            gatewaySwitcher

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

            // Hermes gateway services — hidden while a harness-backed
            // session (Centaur) is front and center: cron/activity/feed/
            // learning are home-gateway ontology, not part of the harness's
            // presentation. Settings and Sessions stay — they're app chrome.
            if chatViewModel.backendCapabilities.supportsGatewayServices {
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
            }

            if chatViewModel.backendCapabilities.supportsSkills {
                Button {
                    showSkills = true
                } label: {
                    Label("Skills", systemImage: "sparkles")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("j", modifiers: .command)
                .accessibilityLabel("Skills")
            }

            if chatViewModel.backendCapabilities.supportsGatewayServices {
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
            }

            if chatViewModel.backendCapabilities.supportsWiki {
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
                        onCreateSessionOnBackend: { entry in
                            Task { await createAndSwitchToNewSession(on: entry) }
                        },
                        sessionScopedBackends: settings.sessionScopedBackends,
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
                    // Quizzes/flashcards now play INLINE inside the Learning
                    // view. This hook only fires if the user explicitly chooses
                    // "Review with Agent" from the results screen — that's the
                    // one case where routing into a chat session is intended.
                    onReviewWithAgent: { prompt in
                        showLearning = false
                        chatViewModel.refocusInput += 1
                        NotificationCenter.default.post(
                            name: .hermesReviewQuiz,
                            object: nil,
                            userInfo: ["reviewPrompt": prompt]
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

            #if os(macOS)
            // Full-window HTML/file preview overlay (driven by HTMLPreviewPresenter).
            // Top of the stack so it covers everything when active.
            HTMLPreviewOverlay()
            #endif
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
        // Check CONTAINMENT, not just .last: the createGeneration observer and
        // createAndSwitchToNewSession can both push the same session in one
        // runloop turn, before SwiftUI commits the first append — .last still
        // reads the old value, so the same destination lands twice and the
        // NavigationStack crashes or breaks back-navigation.
        if !iOSNavigationPath.contains(sessionID) {
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

        // Route the chat pipeline to the backend this session lives on.
        // Session-scoped sessions swap ChatViewModel's client to the entry's
        // backend client; everything else (re)wires the home Hermes gateway
        // (setGatewayClient is identity-guarded, so re-setting the same
        // client is a no-op).
        if let backendID = SessionBackendRegistry.shared.backendID(for: newID),
           let entry = settings.savedGateways.first(where: { $0.id == backendID }),
           entry.kind.isSessionScoped {
            // Same create-race sentinel as the hermes branch: registering the
            // freshly created session flips the list selection, and this
            // handler must not re-resume (re-POST + re-subscribe SSE) on top
            // of the in-flight creation.
            if pendingCreatedSessionID == newID || pendingCreatedSessionID == "__creating__" {
                return
            }
            pendingCreatedSessionID = nil
            if let backend = gatewayClientWrapper.sessionScopedBackend(for: entry) {
                chatViewModel.setGatewayClient(backend)
                pushOwnedSessionOnIOS(newID)
                let generation = chatViewModel.beginSwitchToSession(key: newID)
                Task {
                    _ = await chatViewModel.resumeSession(key: newID, generation: generation)
                }
            } else {
                sessionCreationError = "Backend for this session is gone (removed in Settings?)"
            }
            return
        }
        chatViewModel.setGatewayClient(gatewayClientWrapper.client)

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

    /// Create a new session on a session-scoped backend instead of the
    /// Hermes gateway. Session lists/mission-control stay on the Hermes
    /// path; only the chat pipeline switches backends.
    @MainActor
    private func createSessionOnScopedBackend(_ backend: any AgentBackend, entry: SavedGateway) async {
        chatViewModel.setGatewayClient(backend)
        await chatViewModel.createSession()
        if let error = chatViewModel.error {
            sessionCreationError = "\(entry.displayName) session failed: \(error)"
            return
        }
        if let sid = chatViewModel.currentSessionID {
            log.info("created session \(sid) on \(entry.displayName)")
            pendingCreatedSessionID = sid
            SessionBackendRegistry.shared.bind(sessionID: sid, backendID: entry.id)
            // Register in the sidebar so the session is selectable; the
            // hermes session.list poll won't know it, so mark it owned.
            sessionList.registerOwnedSession(shortHexID: sid)
            sessionList.selectSession(id: sid)
            pushOwnedSessionOnIOS(sid)
        }
    }

    /// Create a session on a specific saved backend entry (nil = home
    /// Hermes gateway). Session-scoped entries skip the WebSocket entirely.
    @MainActor
    private func createAndSwitchToNewSession(on backendEntry: SavedGateway? = nil) async {
        guard !isCreatingSession else { return }
        isCreatingSession = true
        sessionCreationError = nil
        defer { isCreatingSession = false }

        if let entry = backendEntry, entry.kind.isSessionScoped {
            if let backend = gatewayClientWrapper.sessionScopedBackend(for: entry) {
                pendingCreatedSessionID = "__creating__"
                await createSessionOnScopedBackend(backend, entry: entry)
                // A failed create must release the sentinel, or it swallows
                // every subsequent session selection (app looks frozen).
                if sessionCreationError != nil {
                    pendingCreatedSessionID = nil
                }
            } else {
                sessionCreationError = "Backend '\(entry.displayName)' has an invalid URL"
            }
            return
        }

        // connectWithRetry, not a single connectIfNeeded: on iOS the socket
        // dies on every backgrounding, and the first reconnect attempt after
        // foregrounding often races the network path coming back up (radio
        // wake). A failed first connect is terminal without retry, which made
        // "New Session" right after foregrounding reliably fail on iOS.
        await gatewayClientWrapper.connectWithRetry(using: settings)
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

    /// New Session control: a plain button when only the home gateway
    /// exists; a menu offering each backend when session-scoped entries
    /// are saved.
    @ViewBuilder
    private var newSessionControl: some View {
        if settings.sessionScopedBackends.isEmpty {
            Button("New Session") {
                Task { await createAndSwitchToNewSession() }
            }
            .buttonStyle(.borderedProminent)
        } else {
            Menu {
                Button {
                    Task { await createAndSwitchToNewSession() }
                } label: {
                    Label("Hermes (home gateway)", systemImage: BackendKind.hermes.iconName)
                }
                ForEach(settings.sessionScopedBackends) { entry in
                    Button {
                        Task { await createAndSwitchToNewSession(on: entry) }
                    } label: {
                        Label(entry.displayName, systemImage: entry.kind.iconName)
                    }
                }
            } label: {
                Label("New Session", systemImage: "plus")
            } primaryAction: {
                Task { await createAndSwitchToNewSession() }
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
        }
    }

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
        guard let sessionID = notification.userInfo?["session_id"] as? String else { return }
        // Notifications carry whatever ID the gateway event had — usually the
        // runtime short-hex ID, while the sidebar list is keyed by stable
        // database IDs. selectSession(id:) with an unknown ID is a silent
        // no-op (handleSessionSelection can't find the row), which made
        // notification taps land in the app but never open the session.
        // Resolve either form to the list row before selecting; if the list
        // hasn't loaded yet (cold launch from a tap), refresh and retry.
        Task { @MainActor in
            if resolveAndSelectSession(sessionID) { return }
            await sessionList.refreshSessions()
            if !resolveAndSelectSession(sessionID) {
                log.warning("notification tap: session \(sessionID) not found in list")
            }
        }
    }

    /// Select the sidebar row matching a stable DB id OR a runtime gateway id.
    /// Returns false when no row matches.
    @discardableResult
    private func resolveAndSelectSession(_ sessionID: String) -> Bool {
        guard let session = sessionList.sessions.first(where: {
            $0.id == sessionID || $0.gatewayID == sessionID
        }) else { return false }
        sessionList.selectSession(id: session.id)
        return true
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
            // Same ID-resolution as notification taps: the URL may carry a
            // runtime gateway ID while the list is keyed by DB IDs.
            Task { @MainActor in
                if resolveAndSelectSession(id) { return }
                await sessionList.refreshSessions()
                resolveAndSelectSession(id)
            }
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
