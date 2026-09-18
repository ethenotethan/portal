import SwiftUI

// MARK: - Environment plumbing

/// Optional "talk this reply over with the local model" action. The message
/// bubble reads it to show its discuss button; when absent (previews, PDF export,
/// skins rendered outside a chat) the button simply doesn't appear — an
/// environment VALUE, not an EnvironmentObject, so absence is a graceful no-op.
/// Mirrors `openCron` / `openArtifact`.
private struct DiscussMessageKey: EnvironmentKey {
    static let defaultValue: (@MainActor (ChatMessage) -> Void)? = nil
}

extension EnvironmentValues {
    /// Open a local side-discussion anchored to this assistant message.
    internal var discussMessage: (@MainActor (ChatMessage) -> Void)? {
        get { self[DiscussMessageKey.self] }
        set { self[DiscussMessageKey.self] = newValue }
    }
}

// MARK: - Discussion card

/// The inline surface for a local side-discussion: an orb, the exchange so far,
/// and the two ways out — end it, or hand what you decided to the agent.
///
/// It sits in the message stream exactly where `VoiceConversationCard` does, and
/// for the same reason: the reply being discussed stays visible above it. The
/// visual language is deliberately *different* from a normal turn — dashed
/// border, "on-device" label, no avatar — because nothing here is part of the
/// session. These turns cost no tokens and vanish when the card closes.
internal struct LocalDiscussionCard: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    /// The shared service, for the download/load state and error text. The
    /// injectable one on the view model drives behavior; this only reports.
    @ObservedObject private var localChat = LocalChatService.shared
    @State private var draft: String = ""
    @State private var showsAnchor: Bool = false

    internal var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            anchorSection
            if let discussion = chatViewModel.localDiscussion, !discussion.turns.isEmpty {
                turns(discussion)
            }
            if let error = localChat.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            composer
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    Theme.accent.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .accessibilityLabel("Local discussion, \(statusLabel)")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ConversationOrb(
                visual: chatViewModel.conversationVisual,
                phase: chatViewModel.conversationPhase,
                level: Double(chatViewModel.voiceLevel)
            )
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(statusLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text("On-device \u{00B7} \(localChat.model.label) \u{00B7} not part of this session")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer(minLength: 8)
        }
    }

    /// What the card is doing right now, in the user's terms: a multi-gigabyte
    /// first load has to read as progress rather than as a hang.
    private var statusLabel: String {
        if localChat.isPreparing { return "Loading the local model\u{2026}" }
        if chatViewModel.isLocalStreaming { return "Thinking\u{2026}" }
        if chatViewModel.isConversationActive { return "Listening\u{2026}" }
        return isAnchored ? "Discussing this reply" : "Talking it through first"
    }

    /// True when the discussion is about a reply; false when it was started from
    /// the composer to shape what to ask for next.
    private var isAnchored: Bool {
        chatViewModel.localDiscussion?.isAnchored == true
    }

    // MARK: Anchor

    @ViewBuilder
    private var anchorSection: some View {
        if let discussion = chatViewModel.localDiscussion {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showsAnchor.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showsAnchor ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(contextLabel(discussion))
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)

                if showsAnchor {
                    if discussion.isAnchored {
                        Text(discussion.anchorText)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !discussion.draftText.isEmpty {
                        Text("Your draft: \(discussion.draftText)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The sessions the model was briefed on, so what it knows is
                    // inspectable rather than uncanny.
                    ForEach(Array(discussion.briefing.entries.enumerated()), id: \.offset) { _, entry in
                        Text("\u{2022} \(entry.title)\(entry.age.isEmpty ? "" : " \u{2014} \(entry.age)")")
                            .font(.caption)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                }

                // The choices the reply offered, which are usually the actual
                // subject of the conversation.
                if !discussion.options.isEmpty {
                    ForEach(Array(discussion.options.enumerated()), id: \.offset) { index, option in
                        Text("\(index + 1). \(option)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// What the disclosure row is hiding, named for what's actually behind it —
    /// a reply, a draft, or just the briefing.
    private func contextLabel(_ discussion: LocalDiscussion) -> String {
        if discussion.isAnchored { return "About this reply" }
        let sessions = discussion.briefing.entries.count
        if sessions == 0 { return discussion.draftText.isEmpty ? "No context yet" : "Your draft" }
        let known = "knows \(sessions) session\(sessions == 1 ? "" : "s")"
        return discussion.draftText.isEmpty ? "What it knows \u{2014} \(known)" : "Your draft \u{2014} \(known)"
    }

    // MARK: Turns

    private func turns(_ discussion: LocalDiscussion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(discussion.turns) { turn in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: turn.role == .user ? "person.fill" : "cpu")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 14)
                    Text(turn.text.isEmpty && turn.isStreaming ? "\u{2026}" : turn.text)
                        .font(.callout)
                        .foregroundStyle(turn.role == .user ? Theme.secondary : Theme.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Composer

    /// Typing is always available, not just a fallback: a mis-transcribed
    /// question is faster to fix than to re-say, and builds without on-device
    /// transcription still get the whole feature this way.
    private var composer: some View {
        HStack(spacing: 8) {
            TextField(isAnchored ? "Ask about this reply\u{2026}" : "What are we working on?\u{2026}", text: $draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(draft.isEmpty ? Theme.tertiary : Theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send to the local model")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surfaceHover, in: Capsule())
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await chatViewModel.submitLocalDiscussionInput(text) }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            if chatViewModel.localDiscussion?.hasExchange == true {
                Button {
                    Task { await chatViewModel.handLocalDiscussionToAgent() }
                } label: {
                    // Anchored, this submits a turn; from the composer it only
                    // fills the composer — so the label has to say which, or the
                    // button is a surprise either way.
                    Text(isAnchored ? "Hand to Claude" : "Put in composer")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .help(isAnchored
                      ? "Send this side conversation to the agent as the next prompt"
                      : "Write this up into the composer \u{2014} nothing is sent until you send it")
            }

            Button {
                Task { await chatViewModel.endLocalDiscussion() }
            } label: {
                Text("End")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.surfaceHover, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("End local discussion")
        }
    }
}
