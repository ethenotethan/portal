import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import os

/// Main chat interface — skin-aware layout.
/// Delegates all visual rendering to the active ChatSkinProvider,
/// so switching skins changes everything: bubbles, streaming panel, background.
struct ChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore
    @EnvironmentObject var ttsService: TTSService
    @State private var showSkinPicker = false
    @State private var showGatewayDebug = false
    #if os(iOS)
    @State private var showSettings = false
    #endif
    @State private var avatarY: CGFloat = 0
    @State private var pendingScrollTask: Task<Void, Never>?

    // ── Thought Graph ──
    @State private var showThoughtGraph = false
    @StateObject private var thoughtGraphEngine = ThoughtGraphLayoutEngine()

    // ── Quiz Mode ──
    @State private var showQuizSheet = false
    @State private var quizVM = QuizViewModel()

    /// On macOS, owns the chat input focus state at the ChatView level so that
    /// a click anywhere in the detail pane (messages, padding, input card) can
    /// On macOS, owns the chat input focus state at the ChatView level so that
    /// a click anywhere in the detail pane (messages, padding, input card) can
    /// restore focus to the text field.  This fixes the classic SwiftUI/AppKit
    /// bridging issue where clicking the sidebar steals first-responder and
    /// subsequent clicks on transparent padding regions never return it.
    #if os(macOS)
    @FocusState private var isInputFocused: Bool
    /// Weak reference to the native NSTextField backing the input. Used by
    /// ChatPaneClickMonitor to call window.makeFirstResponder() directly.
    @State private var inputFieldRef: FocusableTextView?
    #endif

    /// The active skin — change this to swap the entire visual personality
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui

    /// Current skin provider (recomputed when skin changes)
    private var skinProvider: ChatSkinProviding {
        activeSkin.makeProvider()
    }

    /// Reserve the avatar rail only for skins that render the floating avatar.
    /// TUI uses the full transcript width.
    private var messageLeadingPadding: CGFloat {
        activeSkin == .darkManga ? 72 : 16
    }

    /// Whether any bot content exists (for floating avatar visibility)
    private var hasBotContent: Bool {
        chatViewModel.messages.contains { $0.role == .assistant } || chatViewModel.isStreaming
    }

    // MARK: - Thought Graph Helpers

    /// Whether to show the thought graph toggle button.
    private var shouldShowThoughtGraphToggle: Bool {
        chatViewModel.isStreaming || !chatViewModel.activeToolCalls.isEmpty
    }

    /// Convert activeToolCalls to ThoughtGraphNode array using category-based
    /// dependency inference (search→read→patch/write, terminal→patch) with
    /// parallel-sibling detection.
    private var thoughtGraphNodes: [ThoughtGraphNode] {
        let tools = Array(chatViewModel.activeToolCalls.values)
            .sorted { $0.id < $1.id }
        var nodes = ThoughtGraphLayoutEngine.inferAndLayout(
            tools: tools,
            canvasSize: .zero
        )
        nodes.append(contentsOf: chatViewModel.reasoningGraph.reasoningNodes)
        return nodes
    }

    private var chatBottomContentPadding: CGFloat {
        #if os(macOS)
        if !chatViewModel.isSessionReady { return 260 }
        if chatViewModel.pendingApproval != nil { return 190 }
        // Extra room for multi-line composer (up to 8 lines + attachments/skills)
        return 240
        #else
        8
        #endif
    }

    /// Current avatar expression based on streaming state
    private var currentAvatarExpression: CharacterExpression {
        if chatViewModel.isStreaming {
            switch chatViewModel.avatarState {
            case .thinking: .thinking
            case .speaking: .happy
            case .toolUse:  .thinking
            case .error:    .confused
            default:        .idle
            }
        } else {
            .idle
        }
    }

    var body: some View {
        chatContent
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            chatToolbar
            Divider()
            #endif

            #if os(macOS)
            HStack {
                Spacer()
                // TTS toggle
                Button {
                    ttsService.toggle()
                } label: {
                    Label(ttsService.isEnabled ? "Speaking" : "Muted",
                          systemImage: ttsService.isEnabled ? "speaker.wave.3.fill" : "speaker.slash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(ttsService.isEnabled ? Theme.accent : Theme.secondary)
                .help(ttsService.isEnabled ? "Text-to-speech enabled" : "Text-to-speech disabled")
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            #endif

            // ── Thought Graph (collapsible) ──
            if shouldShowThoughtGraphToggle {
                thoughtGraphSection
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

// Message list
            messageListArea

            #if os(iOS)
            Divider()

            // Approval sheet (if pending)
            if chatViewModel.pendingApproval != nil {
                ApprovalBanner()
                    .environmentObject(chatViewModel)
            }

            // Input bar
            ChatInputBar()
                .environmentObject(chatViewModel)

            // Debug log (always visible while not session-ready)
            if !chatViewModel.isSessionReady {
                DebugLogPanel(wrapper: gatewayClientWrapper)
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        .background(
            ChatPaneClickMonitor(textFieldRef: inputFieldRef)
        )
        #endif
        .eraseToAnyView()
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .simultaneousGesture(
            TapGesture().onEnded { _ in dismissKeyboard() },
            including: .all
        )
        #endif
        .sheet(isPresented: $showGatewayDebug) {
            GatewayDebugPanelView(client: gatewayClientWrapper.client)
                #if os(iOS)
                .presentationDetents([.large])
                #else
                .frame(minWidth: 560, minHeight: 620)
                #endif
        }
        .eraseToAnyView()
        #if os(iOS)
        .fullScreenCover(isPresented: $showThoughtGraph) {
            thoughtGraphFullScreen
        }
        #else
        .sheet(isPresented: $showThoughtGraph) {
                thoughtGraphFullScreen
                    .frame(width: thoughtGraphWidth, height: thoughtGraphHeight)
        }
        #endif
        .sheet(isPresented: $showQuizSheet) {
            QuizSheet(
                viewModel: quizVM,
                onClose: {
                    showQuizSheet = false
                    chatViewModel.clearQuiz()
                },
                onReviewWithAgent: { prompt in
                    let reviewPrompt: String = prompt
                    showQuizSheet = false
                    let _ = Task<Void, Never> { await chatViewModel.reviewQuizWithAgent(prompt: reviewPrompt) }
                }
            )
        }
        .onAppear {
            // no-op: persona is read-only from gateway
            #if os(macOS)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
            #endif
        }
        .onChange(of: chatViewModel.currentSessionID) { _, _ in
            // Close the thought graph when switching sessions
            withAnimation(.easeOut(duration: 0.2)) {
                showThoughtGraph = false
            }
        }
        #if os(macOS)
        .onChange(of: chatViewModel.refocusInput) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
        }
        .onChange(of: chatViewModel.quizQuestions) { _, questions in
            if let questions {
                quizVM.load(questions: questions, topic: chatViewModel.quizTopic)
                showQuizSheet = true
            }
        }
        .onChange(of: chatViewModel.flashcardDeckReady) { _, deck in
            if let deck {
                quizVM.load(deck: deck)
                showQuizSheet = true
            }
        }
        .onChange(of: chatViewModel.errorMessageForQuiz) { _, errorMsg in
            if let errorMsg {
                quizVM.errorMessage = errorMsg
                showQuizSheet = true
            }
        }
        .navigationTitle("")
        .background(activeSkin.background)
        #else
        .navigationTitle(chatViewModel.sessionTitle)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private var latestAssistantTurnProbe: some View {
        if hasBotContent {
            GeometryReader { geo in
                Color.clear.preference(
                    key: LatestBotTurnYKey.self,
                    value: max(0, geo.frame(in: .named("chatContent")).maxY - 60)
                )
            }
            .frame(height: 0)
        }
    }

    private var chatToolbar: some View {
        HStack {
            // Persona badge — tap to switch persona
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

            // Skin badge — tap to switch skin
            Button {
                showSkinPicker = true
            } label: {
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
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSkinPicker) {
                SkinPickerView(activeSkin: $activeSkin)
            }

            // Model badge
            Text(chatViewModel.currentModel.isEmpty ? "No model" : chatViewModel.currentModel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.6), in: Capsule())

            // TTS toggle
            Button {
                ttsService.toggle()
            } label: {
                Image(systemName: ttsService.isEnabled ? "speaker.wave.3.fill" : "speaker.slash")
                    .font(.caption2)
                    .foregroundStyle(ttsService.isEnabled ? Theme.accent : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(ttsService.isEnabled ? "Text-to-speech enabled" : "Text-to-speech disabled")

            Spacer()

            Button {
                showGatewayDebug = true
            } label: {
                Label("Debug Connection", systemImage: "wave.3.right.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Debug Connection")

            #if os(iOS)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            #endif

            if chatViewModel.isStreaming {
                if chatViewModel.isRemoteTurn {
                    HStack(spacing: 4) {
                        Image(systemName: "laptopcomputer.and.iphone")
                            .font(.caption2)
                        Text("Live from another device")
                            .font(.caption2)
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.accent.opacity(0.1), in: Capsule())
                }
                Button {
                    Task { await chatViewModel.interrupt() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }

            if !chatViewModel.isSessionReady && chatViewModel.error == nil {
                HStack(spacing: 4) {
                    HermesProgressView()
                        .scaleEffect(0.7)
                    Text("Creating session…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = chatViewModel.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        #if os(macOS)
        .padding(.vertical, 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(activeSkin.background)
        #else
        .padding(.vertical, 6)
        #endif
    }

    #if os(iOS)
    private var settingsSheet: some View {
        SettingsView()
            .environmentObject(settings)
            .environmentObject(personaManager)
            .environmentObject(capabilitiesStore)
    }
    #endif

    private var messageListArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView(showsIndicators: false) {
                    GeometryReader { viewport in
                        Color.clear.preference(
                            key: ChatViewportHeightKey.self,
                            value: viewport.size.height
                        )
                    }
                    .frame(height: 0)

                    ZStack(alignment: .topLeading) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let msgs = chatViewModel.messages
                            ForEach(renderedMessages, id: \.element.id) { index, message in
                                let isLastInGroup: Bool = Self.isLastMessageInGroup(
                                    message: message,
                                    msgs: msgs
                                )
                                let showTimestamp: Bool = isLastInGroup
                                let preparedMessage: ChatMessage = Self.prepareBubbleMessage(
                                    message, showTimestamp: showTimestamp
                                )
                                skinProvider.messageBubble(
                                    message: preparedMessage,
                                    persona: personaManager.activePersona
                                )
                                .id(message.id)
                            }

                            if chatViewModel.isStreaming {
                                skinProvider.streamingPanel(
                                    state: chatViewModel.avatarState,
                                    activeToolCalls: chatViewModel.activeToolCalls,
                                    personaName: personaManager.activePersona.name,
                                    accentColor: personaManager.activePersona.accentColor
                                )
                                .id("streaming-status")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .padding(.leading, messageLeadingPadding)
                        .padding(.trailing, 16)
                        .padding(.top, 8)
                        .padding(.bottom, chatBottomContentPadding)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        latestAssistantTurnProbe

                        if activeSkin == .darkManga && hasBotContent {
                            FloatingAvatarView(
                                expression: currentAvatarExpression,
                                persona: personaManager.activePersona
                            )
                            .offset(y: avatarY)
                            .padding(.leading, 16)
                        }
                    }
                    .coordinateSpace(name: "chatContent")
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            #if os(macOS)
                VStack(spacing: 8) {
                    if chatViewModel.pendingApproval != nil {
                        ApprovalBanner()
                            .environmentObject(chatViewModel)
                            .padding(.horizontal, 24)
                    }

                    if !chatViewModel.isSessionReady {
                        DebugLogPanel(wrapper: gatewayClientWrapper)
                            .padding(.horizontal, 24)
                    }

                    ChatInputBar(isFocused: $isInputFocused, inputFieldRef: $inputFieldRef)
                        .environmentObject(chatViewModel)
                        .frame(maxWidth: 840, alignment: .center)
                        .id(chatViewModel.currentSessionID ?? "no-session")
                    if let error = chatViewModel.error {
                        ErrorBannerView(error: error) {
                            chatViewModel.error = nil
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .frame(maxWidth: 808, alignment: .bottom)
            #endif
            }
            .background(activeSkin.background)
            #if os(macOS)
            .scrollIndicators(.hidden, axes: .horizontal)
            #else
            .scrollDismissesKeyboard(.interactively)
            #endif
            .onPreferenceChange(LatestBotTurnYKey.self) { y in
                if let y = y {
                    Task { @MainActor in
                        avatarY = y
                    }
                }
            }
            .onPreferenceChange(ChatViewportHeightKey.self) { height in
                if !hasBotContent {
                    Task { @MainActor in
                        await Task.yield()
                        avatarY = max(0, height - 72)
                    }
                }
            }
            .onChange(of: chatViewModel.messages.count) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "message-count")
            }
            .onChange(of: latestMessageRenderKey) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "message-content")
            }
            .onChange(of: activeToolCallRenderKey) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "tool-state")
            }
            .onChange(of: chatViewModel.isStreaming) { _, streaming in
                if streaming { scheduleScrollToBottom(proxy: proxy, reason: "streaming") }
            }
            .onChange(of: chatViewModel.avatarState) { _, _ in
                scheduleScrollToBottom(proxy: proxy, reason: "avatar-state")
            }
            .onDisappear {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
            }
        }
    }

    private var renderedMessages: [(offset: Int, element: ChatMessage)] {
        let enumerated = Array(chatViewModel.messages.enumerated())
        guard ProcessInfo.processInfo.arguments.contains("--virtualize-transcript") else {
            return enumerated
        }
        let keepCount = chatViewModel.isStreaming ? 2 : 4
        return Array(enumerated.suffix(keepCount))
    }

    private var latestMessageRenderKey: String {
        guard let last = chatViewModel.messages.last else { return "none" }
        // Bucket text length so token-by-token deltas do not force a full
        // scroll/layout pass for every tiny chunk. Content still renders as it
        // streams; auto-scroll is just coalesced to reduce main-thread pressure
        // on long sessions.
        let contentBucket = last.content.count / 256
        let reasoningBucket = (last.reasoning?.count ?? 0) / 256
        return "\(last.id.uuidString):\(contentBucket):\(reasoningBucket):\(last.isStreaming)"
    }

    private var activeToolCallRenderKey: String {
        chatViewModel.activeToolCalls
            .sorted { $0.key < $1.key }
            .map { key, value in
                let contextBucket = (value.summary ?? value.context ?? "").count / 256
                return "\(key):\(value.isComplete):\(contextBucket)"
            }
            .joined(separator: "|")
    }

    // MARK: - Thought Graph Section

    @ViewBuilder
    private var thoughtGraphSection: some View {
        VStack(spacing: 0) {
            // ── Open button — presents the graph full-screen so it's
            // actually traversable instead of a cramped inline strip. ──
            Button {
                showThoughtGraph = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.caption)
                    Text("Show Thought Graph")
                        .font(.caption)
                    Spacer()
                    if chatViewModel.isStreaming {
                        Circle()
                            .fill(Color.amber)
                            .frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 6)
        }
    }

    #if os(macOS)
    private var thoughtGraphWidth: CGFloat {
        min((NSScreen.main?.visibleFrame.width ?? 1200) * 0.9, 1600)
    }

    private var thoughtGraphHeight: CGFloat {
        min((NSScreen.main?.visibleFrame.height ?? 800) * 0.9, 1000)
    }
    #endif

    @ViewBuilder
    private var thoughtGraphFullScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agent Thought Graph")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button {
                    showThoughtGraph = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 28, height: 28)
                        .background(Theme.surface, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ThoughtGraphView(
                engine: thoughtGraphEngine,
                nodes: thoughtGraphNodes,
                isStreaming: chatViewModel.isStreaming
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
    }

    private func scheduleScrollToBottom(proxy: ScrollViewProxy, reason: String) {
        _ = reason
        pendingScrollTask?.cancel()
        let delay: UInt64 = chatViewModel.isStreaming ? 500_000_000 : 20_000_000
        pendingScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            scrollToBottom(proxy: proxy)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        let action = {
            if chatViewModel.isStreaming {
                if chatViewModel.activeToolCalls.isEmpty, let lastMsg = chatViewModel.messages.last {
                    proxy.scrollTo(lastMsg.id, anchor: .bottom)
                } else {
                    proxy.scrollTo("streaming-status", anchor: .bottom)
                }
            } else if let lastMsg = chatViewModel.messages.last {
                proxy.scrollTo(lastMsg.id, anchor: .bottom)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--disable-animations") {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, action)
        } else {
            withAnimation(.easeOut(duration: 0.15), action)
        }
    }
}

// MARK: - Floating Avatar (Singleton)
// Exactly one instance. Y position driven by LatestBotTurnYKey preference.
// Animated with easeInOut 400ms.

private struct FloatingAvatarView: View {
    let expression: CharacterExpression
    let persona: Persona

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surface.opacity(0.96))
                    .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 4)

                LottieCharacterView(
                    expression: expression,
                    size: CGSize(width: 48, height: 48)
                )
                .frame(width: 48, height: 48)
            }
            .frame(width: 52, height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(persona.accentColor.opacity(0.55), lineWidth: 1)
            )

            Text(persona.name)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .frame(width: 58)
                .foregroundStyle(persona.accentColor.opacity(0.75))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Preference Key
// Tracks Y position of the latest bot turn within the scroll content coordinate space.
// Multiple assistant messages and the streaming panel report their Y;
// reduce takes the last non-nil value (bottom-most in view tree = latest turn).

private struct LatestBotTurnYKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private struct ChatViewportHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Skin Picker

struct SkinPickerView: View {
    @Binding var activeSkin: ChatSkin

    var body: some View {
        VStack(spacing: 12) {
            Text("Chat Style")
                .font(.headline)

            ForEach(ChatSkin.allCases) { skin in
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        activeSkin = skin
                    }
                } label: {
                    HStack {
                        Image(systemName: skin.icon)
                            .frame(width: 20)
                        Text(skin.displayName)
                            .fontWeight(activeSkin == skin ? .bold : .regular)
                        Spacer()
                        if activeSkin == skin {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(activeSkin == skin ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 200)
    }
}

// MARK: - Input Bar

struct ChatInputBar: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var personaManager: PersonaManager
    @EnvironmentObject var capabilitiesStore: HermesCapabilitiesStore

    /// On macOS, the focus binding is owned by ChatView so that clicks
    /// anywhere in the detail pane can restore focus. On iOS the binding
    /// is nil and ChatInputBar owns its own @FocusState internally.
    #if os(macOS)
    var isFocused: FocusState<Bool>.Binding
    @Binding var inputFieldRef: FocusableTextView?
    #else
    @FocusState private var isInputFocused: Bool
    #endif

    #if os(iOS)
    @State private var selectedPhotosPickerItems: [PhotosPickerItem] = []
    #endif

    private var isSendDisabled: Bool {
        let textEmpty = chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let noAttachments = chatViewModel.pendingAttachments.isEmpty
        return (textEmpty && noAttachments) || chatViewModel.isStreaming
    }

    var body: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            // Attached skills chips
            if !chatViewModel.activeSkills.isEmpty {
                attachedSkillsChips
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
            // Attachment preview strip above input
            if !chatViewModel.pendingAttachments.isEmpty {
                attachmentPreviewStrip
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                attachButton
                inputField
                    .frame(maxWidth: .infinity, alignment: .leading)
                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: 760)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border.opacity(0.9), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 18, x: 0, y: 8)
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
        }
        #else
        VStack(spacing: 0) {
            // Attached skills chips
            if !chatViewModel.activeSkills.isEmpty {
                attachedSkillsChips
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
            }
            // Attachment preview strip above input
            if !chatViewModel.pendingAttachments.isEmpty {
                attachmentPreviewStrip
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
            }
            HStack(alignment: .bottom, spacing: 10) {
                attachButton
                inputField
                sendButton
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
        }
        #endif
    }

    // MARK: - Attached Skills Chips

    private var attachedSkillsChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(chatViewModel.activeSkills) { skill in
                    HStack(spacing: 4) {
                        Text(skill.slashCommand)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.accent)
                        Button {
                            chatViewModel.detachSkill(named: skill.name)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(Theme.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accent.opacity(0.10), in: Capsule())
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attachment Preview Strip

    private var attachmentPreviewStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(chatViewModel.pendingAttachments) { attachment in
                    PendingAttachmentThumbnail(
                        attachment: attachment,
                        onRemove: {
                            chatViewModel.removeAttachment(attachment)
                        }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Attach Button

    private var attachButton: some View {
        #if os(macOS)
        Button {
            showMacFilePicker()
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceHover, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach file")
        .accessibilityIdentifier("attachFileButton")
        .help("Attach a file to your message")
        #else
        Menu {
            PhotosPicker(
                "Photo Library",
                selection: $selectedPhotosPickerItems,
                maxSelectionCount: 5,
                matching: .images
            )
            Button("Choose File") {
                showiOSDocumentPicker()
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 28, height: 28)
                .background(Theme.surfaceHover, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attach file")
        .accessibilityIdentifier("attachFileButton")
        .onChange(of: selectedPhotosPickerItems) { _, newItems in
            handlePhotosPickerItems(newItems)
            selectedPhotosPickerItems = []
        }
        #endif
    }

    // MARK: - Input Field

    private var inputField: some View {
        #if os(macOS)
        ZStack(alignment: .topLeading) {
            MacInputTextField(
                text: $chatViewModel.inputText,
                placeholder: "Message \(personaManager.activePersona.name)…",
                isFocused: isFocused,
                fieldRef: $inputFieldRef,
                onSubmit: { Task { await chatViewModel.submitPrompt() } },
                onImagePaste: { providers in handlePaste(providers: providers) },
                onTextChange: { text in
                    chatViewModel.inputText = text
                    chatViewModel.updateSlashSuggestions()
                },
                onNavigateUp: chatViewModel.slashMode ? { chatViewModel.navigateSlashUp() } : nil,
                onNavigateDown: chatViewModel.slashMode ? { chatViewModel.navigateSlashDown() } : nil,
                onConfirm: chatViewModel.slashMode ? { chatViewModel.confirmSlashSelection() } : nil
            )
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)

            if chatViewModel.slashMode {
                slashAutocompleteOverlay
                    .offset(y: -236)
            }
        }
        .onChange(of: chatViewModel.inputText) { _, _ in
            chatViewModel.updateSlashSuggestions()
        }
        #else
        TextField("Message \(personaManager.activePersona.name)…", text: $chatViewModel.inputText, axis: .vertical)
            .accessibilityIdentifier("chatInput")
            .textFieldStyle(.plain)
            .font(.body)
            .lineLimit(1...8)
            .focused($isInputFocused)
            .onSubmit {
                Task { await chatViewModel.submitPrompt() }
            }
            .onChange(of: chatViewModel.inputText) { _, newValue in
                chatViewModel.updateSlashSuggestions()
            }
            .overlay(alignment: .bottom) {
                if chatViewModel.slashMode {
                    slashAutocompleteOverlay
                }
            }
        #endif
    }

    // MARK: - Slash Autocomplete Overlay

    private var slashAutocompleteOverlay: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 0) {
                        ForEach(Array(chatViewModel.slashSuggestions.enumerated()), id: \.element.id) { idx, skill in
                            Button {
                                chatViewModel.slashSelectedIndex = idx
                                chatViewModel.confirmSlashSelection()
                            } label: {
                                HStack(spacing: 8) {
                                    Text(skill.slashCommand)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(Theme.accent)
                                    Text(skill.name)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.primary)
                                    Spacer()
                                    if !skill.description.isEmpty {
                                        Text(skill.description)
                                            .font(.caption2)
                                            .foregroundStyle(Theme.tertiary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .background(idx == chatViewModel.slashSelectedIndex ? Theme.accent.opacity(0.15) : Color.clear)
                            .id(idx)
                            if idx < chatViewModel.slashSuggestions.count - 1 {
                                Divider().background(Theme.border)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .onChange(of: chatViewModel.slashSelectedIndex) { _, newIdx in
                    withAnimation {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 4)
    }

    // MARK: - Send Button

    private var sendButton: some View {
        Button {
            Task { await chatViewModel.submitPrompt() }
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isSendDisabled ? Theme.tertiary : Theme.primary)
                .frame(width: 30, height: 30)
                .background(isSendDisabled ? Theme.surfaceHover : Theme.accent, in: Circle())
        }
        .accessibilityLabel("Send")
        .accessibilityIdentifier("sendButton")
        .disabled(isSendDisabled)
        .buttonStyle(.plain)
    }

    // MARK: - macOS File Picker

    #if os(macOS)
    private func showMacFilePicker() {
        let panel = NSOpenPanel()
        panel.title = "Select Files"
        panel.allowedContentTypes = [.item]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            let cachedPath = Self.copyToCache(url: url)
            guard !cachedPath.isEmpty else { continue }
            chatViewModel.addAttachment(path: cachedPath)
        }
    }
    #endif

    // MARK: - iOS Document Picker

    #if os(iOS)
    @MainActor
    private func showiOSDocumentPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else { return }

        let docPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        docPicker.allowsMultipleSelection = true
        docPicker.delegate = DocumentPickerDelegate.shared

        DocumentPickerDelegate.shared.onSelect = { urls in
            for url in urls {
                let cachedPath = Self.copyToCache(url: url)
                guard !cachedPath.isEmpty else { continue }
                chatViewModel.addAttachment(path: cachedPath)
            }
        }

        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(docPicker, animated: true)
    }
    #endif

    // MARK: - iOS Photos Picker Handler

    #if os(iOS)
    private func handlePhotosPickerItems(_ items: [PhotosPickerItem]) {
        for item in items {
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                await MainActor.run {
                    chatViewModel.addAttachment(path: cachedPath)
                }
            }
        }
    }
    #endif

    // MARK: - Paste Handler (macOS)

    #if os(macOS)
    private func handlePaste(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let data = item as? Data {
                        let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let nsImage = item as? NSImage,
                              let tiffData = nsImage.tiffRepresentation,
                              let bitmapRep = NSBitmapImageRep(data: tiffData),
                              let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                        let cachedPath = Self.saveImageDataToCache(data: pngData, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let url = item as? URL {
                                let cachedPath = Self.copyToCache(url: url)
                                guard !cachedPath.isEmpty else { return }
                                Task { @MainActor in
                                    chatViewModel.addAttachment(path: cachedPath)
                                }
                            }
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let ext = url.pathExtension.lowercased()
                        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif"]
                        guard imageExts.contains(ext) else { return }
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            }
        }
    }
    #endif

    // MARK: - Drop Handler

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    } else if let data = item as? Data {
                        let cachedPath = Self.saveImageDataToCache(data: data, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                    #if os(macOS)
                    if let nsImage = item as? NSImage,
                       let tiffData = nsImage.tiffRepresentation,
                       let bitmapRep = NSBitmapImageRep(data: tiffData),
                       let pngData = bitmapRep.representation(using: .png, properties: [:]) {
                        let cachedPath = Self.saveImageDataToCache(data: pngData, ext: "png")
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                    #endif
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                            if let url = item as? URL {
                                let cachedPath = Self.copyToCache(url: url)
                                guard !cachedPath.isEmpty else { return }
                                Task { @MainActor in
                                    chatViewModel.addAttachment(path: cachedPath)
                                }
                            }
                        }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    if let url = item as? URL {
                        let ext = url.pathExtension.lowercased()
                        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif"]
                        guard imageExts.contains(ext) else { return }
                        let cachedPath = Self.copyToCache(url: url)
                        guard !cachedPath.isEmpty else { return }
                        Task { @MainActor in
                            chatViewModel.addAttachment(path: cachedPath)
                        }
                    }
                }
            }
        }
        return handled
    }

    // MARK: - Cache Helpers

    /// Directory for cached user-sent images.
    private static var hermesImagesDir: String {
        let home = NSHomeDirectory()
        let dir = "\(home)/.hermes/images"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copy a file URL into the hermes images cache, returning the cached path.
    private static func copyToCache(url: URL) -> String {
        let dir = hermesImagesDir
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = "\(dir)/\(fileName)"
        do {
            try FileManager.default.copyItem(atPath: url.path, toPath: dest)
            return dest
        } catch {
            os_log(.error, "Failed to copy file to cache: %{public}@ -> %{public}@: %{public}@",
                   url.path, dest, error.localizedDescription)
            return url.path
        }
    }

    private static func saveImageDataToCache(data: Data, ext: String) -> String {
        let dir = hermesImagesDir
        let fileName = "\(UUID().uuidString).\(ext)"
        let dest = "\(dir)/\(fileName)"
        do {
            try data.write(to: URL(fileURLWithPath: dest))
            return dest
        } catch {
            os_log(.error, "Failed to save image data to cache %{public}@: %{public}@",
                   dest, error.localizedDescription)
            return ""
        }
    }
}

// MARK: - Pending Attachment Thumbnail

private struct PendingAttachmentThumbnail: View {
    let attachment: MediaAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail
            ThumbnailImageView(data: attachment.thumbnailData, fallbackIcon: attachment.category.icon)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.border, lineWidth: 0.5)
                )

            // Remove button
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.primary)
                    .background(Circle().fill(Theme.surface).opacity(0.8))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
        }
    }
}

// MARK: - iOS Document Picker Delegate

#if os(iOS)
final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerDelegate()
    var onSelect: ([URL]) -> Void = { _ in }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onSelect(urls)
    }
}
#endif

// MARK: - Debug Log Panel

struct DebugLogPanel: View {
    @ObservedObject var wrapper: GatewayClientWrapper

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(wrapper.log) { entry in
                        Text(entry.text)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(entry.isError ? .red : .secondary)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .onChange(of: wrapper.log.count) { _, _ in
                if let last = wrapper.log.last {
                    proxy.scrollTo(last.id)
                }
            }
        }
    }
}

// MARK: - Approval Banner

struct ApprovalBanner: View {
    @EnvironmentObject var chatViewModel: ChatViewModel

    var body: some View {
        if let approval = chatViewModel.pendingApproval {
            HStack {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.yellow)

                VStack(alignment: .leading) {
                    Text("Approval Required")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Text(approval.command.truncated(to: 100))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("Deny") {
                    Task { await chatViewModel.respondApproval(choice: "deny") }
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .controlSize(.small)

                Button("Approve") {
                    Task { await chatViewModel.respondApproval(choice: "approve") }
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .controlSize(.small)
            }
            .padding(10)
            .background(.yellow.opacity(0.1))
        }
    }
}

// MARK: - Message grouping helpers

extension ChatView {
    /// Returns `true` if `message` is the last in a consecutive same-role group.
    /// We look up `message.id` in `msgs` to get the array position, then check the next message's role.
    static func isLastMessageInGroup(message: ChatMessage, msgs: [ChatMessage]) -> Bool {
        guard let msgIndex = msgs.firstIndex(where: { $0.id == message.id }) else {
            return true // if not found, treat as group boundary for safety
        }
        let nextIdx = msgIndex + 1
        guard nextIdx < msgs.count else {
            return true // last message overall
        }
        let nextRole = msgs[nextIdx].role
        return nextRole != message.role
    }

    /// Creates a variant of `message` with avatar hidden and timestamp set for bubble rendering.
    static func prepareBubbleMessage(_ message: ChatMessage, showTimestamp: Bool) -> ChatMessage {
        var m = message
        m.showAvatar = false
        m.showTimestamp = showTimestamp
        return m
    }
}

// MARK: - Keyboard Dismissal (iOS)

#if os(iOS)
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif

// MARK: - Error Banner

private struct ErrorBannerView: View {
    let error: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
            Text(error)
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.9))
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
