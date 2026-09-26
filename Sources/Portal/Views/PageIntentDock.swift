import SwiftUI

/// The floating "Talk to this page" button that opens the intent dock.
@MainActor
internal struct PageIntentDockButton: View {
    internal let action: () -> Void

    internal var body: some View {
        Button(action: action) {
            Label("Talk to this page", systemImage: "waveform.and.mic")
                .labelStyle(.iconOnly)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Theme.primary)
                .frame(width: 44, height: 44)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .help("Talk to this page: ask about it or tell the agent what to do here")
        .accessibilityLabel("Talk to this page")
        .padding(18)
    }
}

/// The dock that slides up from the bottom of a graph page: the page's context,
/// the voice conversation card and the transcript, with a text composer so the
/// same session can be typed at. The dock renders whatever session the model
/// says is active; it never owns one.
@MainActor
internal struct PageIntentDock: View {
    @ObservedObject internal var model: PageIntentDockModel
    internal let persona: Persona
    internal let skinProvider: ChatSkinProviding
    @State private var showsContext = false

    internal static let height: CGFloat = 340

    internal var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.border)
            if let chat = model.activeChat {
                conversation(chat)
            } else {
                Text(model.status ?? "Starting a session for this page…")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .top) { Divider().background(Theme.border) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.and.mic")
                    .foregroundStyle(Theme.secondary)
                Text(model.context?.title ?? "This page")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                if model.isOpening {
                    ProgressView().controlSize(.small)
                }
                if let status = model.status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                }
                Spacer()
                Button(showsContext ? "Hide context" : "Context") { showsContext.toggle() }
                    .portalButton(prominent: false, size: .small)
                Button("Open in Chat") { model.openInChat() }
                    .portalButton(prominent: false, size: .small)
                    .disabled(model.activeChat?.currentSessionID == nil)
                Button {
                    Task { await model.close() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Close (the session stays; reopening continues it)")
                .accessibilityLabel("Close")
            }
            if showsContext, let context = model.context {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(context.stateLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func conversation(_ chat: ChatViewModel) -> some View {
        VStack(spacing: 0) {
            if chat.isConversationActive {
                VoiceConversationCard(chatViewModel: chat)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ConversationPanel(chatViewModel: chat, persona: persona, skinProvider: skinProvider)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer(chat)
        }
    }

    private func composer(_ chat: ChatViewModel) -> some View {
        HStack(spacing: 8) {
            TextField("Ask about this page, or say what to do…", text: Binding(
                get: { chat.inputText },
                set: { chat.inputText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
            .onSubmit { Task { await chat.submitPrompt() } }
            if chat.isConversationActive {
                Button {
                    Task { await chat.endConversation() }
                } label: {
                    Image(systemName: "mic.slash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Stop listening")
            } else {
                Button {
                    Task { await chat.startVoiceConversation() }
                } label: {
                    Image(systemName: "mic")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Start listening")
            }
            Button("Send") { Task { await chat.submitPrompt() } }
                .portalButton(prominent: true, size: .small)
                .disabled(chat.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isStreaming)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }
}
