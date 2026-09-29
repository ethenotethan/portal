import SwiftUI

/// Explicit chat and voice launchers for the current graph page. Context is
/// already preloaded; neither mode expands or starts local voice work until its
/// own button is pressed.
@MainActor
internal struct PageIntentDockButton: View {
    internal let action: (PageIntentMode) -> Void

    internal var body: some View {
        HStack(spacing: 4) {
            ForEach(PageIntentMode.allCases) { mode in
                Button { action(mode) } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 10)
                        .frame(height: Self.height)
                }
                .buttonStyle(.plain)
                .help("Open \(mode.title.lowercased()) for this page")
                .accessibilityLabel("Open \(mode.title) for this page")
            }
        }
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .padding(Self.outerPadding)
    }
}

/// The dock that slides up from the bottom of a graph page: the page's context
/// plus either the explicitly selected voice card or the chat transcript and
/// composer. Both modes share the same preloaded session. The dock renders
/// whatever session the model says is active; it never owns one.
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
            if let chat = model.activeChat, let mode = model.activeMode {
                switch mode {
                case .chat:
                    chatConversation(chat)
                case .voice:
                    voiceConversation(chat)
                }
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
                ForEach(PageIntentMode.allCases) { mode in
                    Button {
                        guard let context = model.context else { return }
                        Task { await model.open(context: context, mode: mode) }
                    } label: {
                        Label(mode.title, systemImage: mode.systemImage)
                    }
                    .portalButton(prominent: model.activeMode == mode, size: .small)
                }
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

    private func chatConversation(_ chat: ChatViewModel) -> some View {
        VStack(spacing: 0) {
            ConversationPanel(chatViewModel: chat, persona: persona, skinProvider: skinProvider)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer(chat)
        }
        // The transcript's subviews (EmptyTranscriptStateView, the approval and
        // clarify banners) read the ChatViewModel from the environment, the way
        // ChatView provides it; the dock hosts a per-scope model, so it must
        // provide that model itself or the first empty transcript traps.
        .environmentObject(chat)
    }

    private func voiceConversation(_ chat: ChatViewModel) -> some View {
        VoiceConversationCard(chatViewModel: chat)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environmentObject(chat)
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

extension PageIntentDockButton {
    private static let height: CGFloat = 40
    private static let outerPadding: CGFloat = 18
    /// Horizontal footprint consumed by the floating button at the trailing
    /// edge. Graph-local overlays reserve this width so neither control owns
    /// the same hit target.
    internal static let reservedWidth: CGFloat = 180
}
