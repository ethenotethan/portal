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

// MARK: - Discussion pane

/// The surface for a local side-discussion: a pane that breaks away over the
/// chat, holds the whole exchange start to finish, and collapses when the
/// conversation has produced its output.
///
/// A pane rather than a card in the message stream, because the stream is the
/// wrong shape for this. A back-and-forth that is still happening needs room to
/// be read as it grows, and the stream gave it one tile wedged between the last
/// reply and the composer — the exchange was all there and still felt like it
/// was disappearing. Here the thread has the height of the window, follows
/// itself as it grows, and everything else is dimmed behind it: for as long as
/// this is open, this is the conversation.
///
/// The visual language is still deliberately *different* from a normal turn —
/// dashed border, "on-device" label, no avatar — because nothing here is part of
/// the session. These turns cost no tokens and the pane leaving is what puts the
/// conclusion into the composer and sends it.
internal struct LocalDiscussionPane: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    /// The shared service, for the download/load state and error text. The
    /// injectable one on the view model drives behavior; this only reports.
    @ObservedObject private var localChat = LocalChatService.shared
    /// Owns the live output loudness so the header orb breathes with the
    /// spoken reply, matching the inline conversation card.
    @ObservedObject private var tts = TTSService.shared
    @State private var draft: String = ""
    @State private var showsAnchor: Bool = false
    /// Open throttle window for following the thread as it grows.
    @State private var followTask: Task<Void, Never>?
    /// Drives the settle-in on open; the pane's removal is animated by the chat.
    @State private var isSettled: Bool = false
    @FocusState private var composerFocused: Bool

    private static let threadEnd = "local-discussion-thread-end"

    internal var body: some View {
        ZStack {
            // Tapping the chat behind the pane puts the discussion aside, the same as
            // Close: the exchange is kept either way.
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
                .accessibilityHidden(true)

            panel
                .frame(maxWidth: 820)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .scaleEffect(isSettled ? 1 : 0.96)
                .opacity(isSettled ? 1 : 0)
        }
        #if os(macOS)
        .onExitCommand(perform: close)
        #endif
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { isSettled = true }
            composerFocused = true
        }
        .onDisappear {
            followTask?.cancel()
            followTask = nil
        }
        .accessibilityLabel("Local discussion, \(statusLabel)")
    }

    private var panel: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            Divider().overlay(Theme.border)
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        anchorSection
                        if let error = localChat.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let discussion = chatViewModel.localDiscussion {
                            if hasThread(discussion) {
                                thread(discussion)
                            } else {
                                emptyThread
                            }
                        }
                        // What the follow scrolls to: the bottom edge of whatever the
                        // newest line is, rather than a turn id that changes every time.
                        Color.clear
                            .frame(height: 1)
                            .id(Self.threadEnd)
                    }
                    .padding(18)
                }
                .onAppear {
                    // A resumed thread opens at the end, where the conversation is.
                    proxy.scrollTo(Self.threadEnd, anchor: .bottom)
                }
                .onChange(of: chatViewModel.localDiscussionRenderKey) { _, _ in
                    follow(proxy)
                }
            }
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 10) {
                composer
                actions
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    Theme.accent.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
        .shadow(color: .black.opacity(0.28), radius: 28, y: 10)
    }

    // MARK: Header

    /// Mic level while listening, the assistant's output level while speaking,
    /// at rest while thinking — so the header orb reacts to whoever is talking.
    private var orbLevel: Double {
        switch chatViewModel.conversationPhase {
        case .listening: Double(chatViewModel.voiceLevel)
        case .speaking: Double(tts.outputLevel)
        case .thinking: 0
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ConversationOrb(
                visual: chatViewModel.conversationVisual,
                phase: chatViewModel.conversationPhase,
                level: orbLevel
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

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 26, height: 26)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
            // Not "End": the exchange is kept, and re-opening picks it up where
            // it stopped. Calling that "end" would make resuming a surprise.
            .help("Put this aside \u{2014} it's still here when you come back")
            .accessibilityLabel("Close local discussion")
        }
    }

    /// What the pane is doing right now, in the user's terms: a multi-gigabyte
    /// first load has to read as progress rather than as a hang.
    private var statusLabel: String {
        if localChat.isPreparing { return "Loading the local model\u{2026}" }
        if chatViewModel.isDraftingHandoff { return "Writing the prompt\u{2026}" }
        if chatViewModel.isLocalStreaming { return "Thinking\u{2026}" }
        if chatViewModel.isConversationActive { return "Listening\u{2026}" }
        return isAnchored ? "Discussing this reply" : "Talking it through first"
    }

    /// True when the discussion is about a reply; false when it was started from
    /// the composer to shape what to ask for next.
    private var isAnchored: Bool {
        chatViewModel.localDiscussion?.isAnchored == true
    }

    private func close() {
        Task { await chatViewModel.endLocalDiscussion() }
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

    // MARK: Thread

    /// The exchange so far, start to finish, as a thread hanging off the rule.
    ///
    /// Nothing is folded: the whole point of the pane is that the conversation can
    /// be read in full while it is happening. Each turn is attributed and never
    /// truncated, the newest is always in view (`follow`), and a resumed thread
    /// shows the seam where it was picked up.
    private func thread(_ discussion: LocalDiscussion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(Theme.accent.opacity(0.3))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(discussion.turns.enumerated()), id: \.element.id) { index, turn in
                    if index == discussion.resumedAt {
                        resumeMarker
                    }
                    turnRow(turn)
                }
                // What the user is saying right now, before the transcriber commits
                // to it. Provisional styling, because these words can still change.
                if let live = chatViewModel.localDiscussionLiveUtterance {
                    liveRow(live)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.easeOut(duration: 0.18), value: discussion.turns.count)
    }

    /// Before anything has been said: what this is for, and how it ends.
    private var emptyThread: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isAnchored ? "Talk this reply over." : "Talk through what you want to ask for.")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
            Text("Speak, or type below. When you've landed on it, say \u{201C}okay, submit\u{201D} and it goes to Claude as the next prompt.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    /// The seam where a set-aside discussion was picked up again. Without it a
    /// resumed thread looks like one unbroken sitting, and the user loses track of
    /// what the model was told versus what it actually remembers.
    private var resumeMarker: some View {
        HStack(spacing: 6) {
            Text("Picked up here")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            Rectangle()
                .fill(Theme.tertiary.opacity(0.25))
                .frame(height: 1)
        }
        .padding(.top, 2)
    }

    private func turnRow(_ turn: LocalDiscussionTurn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.role == .user ? "You" : localChat.model.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(turn.role == .user ? Theme.tertiary : Theme.accent.opacity(0.85))
            Text(turn.text.isEmpty && turn.isStreaming ? "\u{2026}" : turn.text)
                .font(.body)
                .foregroundStyle(turn.role == .user ? Theme.secondary : Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .id(turn.id)
    }

    private func liveRow(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You \u{00B7} speaking\u{2026}")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.tertiary)
            Text("\u{201C}\(text)\u{201D}")
                .font(.body.italic())
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.opacity)
    }

    /// Whether there is anything to show under the rule yet — turns, or words the
    /// user is in the middle of saying.
    private func hasThread(_ discussion: LocalDiscussion) -> Bool {
        !discussion.turns.isEmpty || chatViewModel.localDiscussionLiveUtterance != nil
    }

    /// Keep the newest line in view, at most a handful of times a second.
    ///
    /// A throttle rather than a debounce, because a local reply arrives as a dense
    /// run of deltas: a debounce cancels itself on every one of them and only ever
    /// scrolls once generation has stopped, which is precisely the "I can't watch
    /// it happen" problem the pane exists to fix. The trailing edge is covered
    /// either way — the last change of a run falls inside a pending window or
    /// opens a new one.
    private func follow(_ proxy: ScrollViewProxy) {
        guard followTask == nil else { return }
        followTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
                followTask = nil
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.threadEnd, anchor: .bottom)
                }
            } catch {
                // Sleep only throws on cancellation, which here means the pane is
                // going away: close the window and scroll nothing.
                followTask = nil
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
                .focused($composerFocused)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceHover, in: Capsule())
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await chatViewModel.submitLocalDiscussionInput(text) }
    }

    // MARK: Actions

    /// The ways out, and the hint that says none of them is needed: the close-out
    /// is sayable, and the buttons are for when you'd rather not.
    private var actions: some View {
        HStack(spacing: 8) {
            if hasExchange {
                Text("or just say \u{201C}okay, submit\u{201D}")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
            }

            Spacer(minLength: 0)

            if hasExchange {
                Button {
                    Task { await chatViewModel.restartLocalDiscussion() }
                } label: {
                    Text("Start over")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.surfaceHover, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Throw this exchange away and start the same discussion again")

                Button {
                    Task { await chatViewModel.handLocalDiscussionToAgent() }
                } label: {
                    Text("Submit")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.18), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(chatViewModel.isDraftingHandoff)
                .help("Have the local model write this up as a prompt, and send it to Claude")
            }
        }
    }

    private var hasExchange: Bool {
        chatViewModel.localDiscussion?.hasExchange == true
    }
}
