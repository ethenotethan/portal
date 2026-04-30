import SwiftUI

/// Main chat interface — skin-aware layout.
/// Delegates all visual rendering to the active ChatSkinProvider,
/// so switching skins changes everything: bubbles, streaming panel, background.
struct ChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var personaManager: PersonaManager
    @State private var showPersonaPicker = false
    @State private var showSkinPicker = false
    #if os(iOS)
    @State private var showSettings = false
    #endif
    @State private var avatarY: CGFloat = 0

    /// The active skin — change this to swap the entire visual personality
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui

    /// Current skin provider (recomputed when skin changes)
    private var skinProvider: ChatSkinProviding {
        activeSkin.makeProvider()
    }

    /// Whether any bot content exists (for floating avatar visibility)
    private var hasBotContent: Bool {
        chatViewModel.messages.contains { $0.role == .assistant } || chatViewModel.isStreaming
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
        VStack(spacing: 0) {
            // Toolbar
            chatToolbar

            Divider()

            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(chatViewModel.messages.enumerated()), id: \.element.id) { index, message in
                                let msgs = chatViewModel.messages
                                // Next message in same role group?
                                let nextIsSameRole = index < msgs.count - 1 &&
                                    msgs[index + 1].role == message.role
                                let isLastInGroup = !nextIsSameRole

                                // Dark Manga: avatar is a singleton overlay, not per-bubble
                                let showAvatar = activeSkin == .darkManga ? false :
                                    (message.role == .assistant && isLastInGroup && !chatViewModel.isStreaming)

                                // Timestamp: only on the last message in a consecutive group
                                let showTimestamp = isLastInGroup

                                skinProvider.messageBubble(
                                    message: {
                                        var m = message
                                        m.showAvatar = showAvatar
                                        m.showTimestamp = showTimestamp
                                        return m
                                    }(),
                                    persona: personaManager.activePersona
                                )
                                .id(message.id)
                                // Report Y position for floating avatar (Dark Manga only)
                                .background {
                                    if activeSkin == .darkManga && message.role == .assistant {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: LatestBotTurnYKey.self,
                                                value: geo.frame(in: .named("chatContent")).minY
                                            )
                                        }
                                    }
                                }
                            }

                            // Streaming panel — skin-provided
                            if chatViewModel.isStreaming {
                                skinProvider.streamingPanel(
                                    state: chatViewModel.avatarState,
                                    activeToolCalls: chatViewModel.activeToolCalls,
                                    personaName: personaManager.activePersona.name,
                                    accentColor: personaManager.activePersona.accentColor
                                )
                                .id("streaming-status")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .background {
                                    if activeSkin == .darkManga {
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: LatestBotTurnYKey.self,
                                                value: geo.frame(in: .named("chatContent")).minY
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.leading, activeSkin == .darkManga ? 80 : 12)
                        .padding(.trailing, 8)
                        .padding(.vertical, 8)

                        // ── Singleton floating avatar (Dark Manga only) ──
                        // Exactly one avatar element. Animated Y tracks latest bot turn.
                        if activeSkin == .darkManga && hasBotContent {
                            FloatingAvatarView(expression: currentAvatarExpression)
                                .offset(y: avatarY)
                                .padding(.leading, 16)
                        }
                    }
                    .coordinateSpace(name: "chatContent")
                }
                .background(activeSkin.background)
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onPreferenceChange(LatestBotTurnYKey.self) { y in
                    if let y = y {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            avatarY = y
                        }
                    }
                }
                .onChange(of: chatViewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatViewModel.messages.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatViewModel.avatarState) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("streaming-status", anchor: .bottom)
                    }
                }
            }

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
        }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 400)
        #endif
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .onTapGesture {
            dismissKeyboard()
        }
        #endif
        .onAppear {
            chatViewModel.personaManager = personaManager
            if !chatViewModel.isSessionReady {
                Task {
                    await chatViewModel.createSession()
                }
            }
        }
    }

    private var chatToolbar: some View {
        HStack {
            // Persona badge — tap to switch persona
            Button {
                showPersonaPicker = true
            } label: {
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
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPersonaPicker) {
                PersonaPickerView()
                    .environmentObject(personaManager)
            }

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

            Spacer()

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
                    ProgressView().controlSize(.small)
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
        .padding(.vertical, 6)
    }

    #if os(iOS)
    private var settingsSheet: some View {
        SettingsView()
            .environmentObject(settings)
            .environmentObject(personaManager)
    }
    #endif

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if let lastMsg = chatViewModel.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                if chatViewModel.isStreaming {
                    proxy.scrollTo("streaming-status", anchor: .bottom)
                } else {
                    proxy.scrollTo(lastMsg.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Floating Avatar (Singleton)
// Exactly one instance. Y position driven by LatestBotTurnYKey preference.
// Animated with easeInOut 400ms.

private struct FloatingAvatarView: View {
    let expression: CharacterExpression

    var body: some View {
        VStack(spacing: 4) {
            LottieCharacterView(
                expression: expression,
                size: CGSize(width: 48, height: 48)
            )
            .frame(width: 48, height: 48)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
            )

            Text("Creative")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(0.6))
        }
    }
}

// MARK: - Preference Key
// Tracks Y position of the latest bot turn within the scroll content coordinate space.
// Multiple assistant messages and the streaming panel report their Y;
// reduce takes the last non-nil value (bottom-most in view tree = latest turn).

private struct LatestBotTurnYKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
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
    @FocusState private var isInputFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message \(personaManager.activePersona.name)…", text: $chatViewModel.inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($isInputFocused)
                .onSubmit {
                    Task { await chatViewModel.submitPrompt() }
                }

            Button {
                Task { await chatViewModel.submitPrompt() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatViewModel.isStreaming ? .gray : Color.accentColor)
            }
            .disabled(chatViewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatViewModel.isStreaming)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

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

// MARK: - Keyboard Dismissal (iOS)

#if os(iOS)
private func dismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
#endif
