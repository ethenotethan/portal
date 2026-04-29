import SwiftUI

/// Main chat interface — message list + input bar + tool calls sidebar.
struct ChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @EnvironmentObject var gatewayClientWrapper: GatewayClientWrapper
    @EnvironmentObject var personaManager: PersonaManager
    @State private var showPersonaPicker = false

    /// The message ID the avatar is currently trailing (last assistant or streaming)
    private var avatarTrailingMessageID: UUID? {
        // Find the last assistant message (streaming first, then last completed)
        if let streaming = chatViewModel.messages.last(where: { $0.isStreaming && $0.role == .assistant }) {
            return streaming.id
        }
        return chatViewModel.messages.last(where: { $0.role == .assistant })?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            chatToolbar

            Divider()

            // Message list — avatar flows inline
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chatViewModel.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)

                            // Inline avatar — trails the last/streaming assistant message
                            if message.id == avatarTrailingMessageID {
                                InlineAvatarView(
                                    state: chatViewModel.avatarState,
                                    persona: personaManager.activePersona,
                                    isStreaming: chatViewModel.isStreaming
                                )
                                .id("avatar-trailing")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .padding()
                    .padding(.bottom, 16)
                }
                .onChange(of: chatViewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatViewModel.messages.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatViewModel.avatarState) { _, _ in
                    // Keep avatar visible when state changes
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("avatar-trailing", anchor: .bottom)
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
                proxy.scrollTo("avatar-trailing", anchor: .bottom)
            }
        }
    }
}

// MARK: - Inline Avatar

/// Avatar that flows inline with the conversation, trailing the last assistant message.
/// Shows the 3D character + state label, sized to feel like part of the chat.
struct InlineAvatarView: View {
    let state: AvatarState
    let persona: Persona
    let isStreaming: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 3D Avatar
            Avatar3DView(
                state: state,
                accentColorHex: persona.accentColorHex,
                accessories: persona.accessories,
                size: 64
            )
            .shadow(color: persona.accentColor.opacity(0.25), radius: 6)

            // State + persona info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(persona.name)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(persona.accentColor)

                    AvatarStateLabel(state: state)
                }

                if isStreaming {
                    Text(state == .thinking ? "Processing…" : state == .toolUse ? "Running tools…" : "Responding…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.leading, 4)
        .animation(.easeInOut(duration: 0.25), value: state)
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
