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

    /// The active skin — change this to swap the entire visual personality
    @AppStorage("chatSkin") private var activeSkin: ChatSkin = .tui

    /// Current skin provider (recomputed when skin changes)
    private var skinProvider: ChatSkinProviding {
        activeSkin.makeProvider()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            chatToolbar

            Divider()

            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(chatViewModel.messages.enumerated()), id: \.element.id) { index, message in
                            let msgs = chatViewModel.messages
                            // Next message in same role group?
                            let nextIsSameRole = index < msgs.count - 1 &&
                                msgs[index + 1].role == message.role
                            let isLastInGroup = !nextIsSameRole

                            // Traveling avatar: only the LAST assistant message shows the avatar
                            // when NOT streaming. During streaming, the streaming panel owns it.
                            let showAvatar = message.role == .assistant &&
                                isLastInGroup &&
                                !chatViewModel.isStreaming

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
                        }
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                }
                .background(activeSkin.background)
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
        .frame(minWidth: 600, minHeight: 400)
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
