import SwiftUI

/// Main chat interface — message list + input bar + tool calls sidebar.
struct ChatView: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @EnvironmentObject var settings: SettingsViewModel
    @State private var scrollViewProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            chatToolbar

            Divider()

            // Message list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(chatViewModel.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: chatViewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: chatViewModel.messages.last?.content) { _, _ in
                    scrollToBottom(proxy: proxy)
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
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            if !chatViewModel.isSessionReady {
                Task {
                    await chatViewModel.createSession()
                }
            }
        }
    }

    private var chatToolbar: some View {
        HStack {
            // Model badge
            HStack(spacing: 4) {
                Circle()
                    .fill(chatViewModel.isStreaming ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)

                Text(chatViewModel.currentModel.isEmpty ? "No model" : chatViewModel.currentModel)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())

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
                proxy.scrollTo(lastMsg.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Input Bar

struct ChatInputBar: View {
    @EnvironmentObject var chatViewModel: ChatViewModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Hermes…", text: $chatViewModel.inputText, axis: .vertical)
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
