import SwiftUI

/// The live chat conversation as a dashboard panel: the real transcript — the
/// same messages, streaming the same way — rendered inside a resizable canvas
/// panel instead of owning the whole screen. It is NOT a snapshot or a copy: it
/// observes the live `ChatViewModel`, so tokens stream in and bubbles grow here
/// exactly as they do in the normal chat.
///
/// This is a plain transcript: message bubbles, and a streaming-status line
/// under the live turn. It deliberately does NOT inject a per-turn lens rail or
/// a docked lens section beneath the bubbles — that inline lens-embedding layer
/// was a second place the same activity rendered (thinking already shows inside
/// the bubble via `ReasoningSection`/`ThinkingTraceSection`), and its peel/dock
/// affordance overlaid an extra tappable subview on the pane rather than letting
/// the arrangement be edited in place. Turn activity now lives in one place: the
/// bubble for reasoning/tools, and the canvas lens TILES (added from the palette,
/// e.g. flamechart / tools / thinking) for anyone who wants the plotted view.
///
/// Timer-free: it re-renders on `ChatViewModel` publishes (new / grown messages,
/// streaming toggles), never on a clock.
/// A per-turn block that can be peeled out of its bubble and mirrored as a card
/// layered into the scroll beneath the turn that produced it. "Mirror" — the
/// bubble keeps its own copy; this is a second, live view of the same content.
internal enum PeeledBlockKind: String, CaseIterable, Hashable {
    case thinking
    case tools

    internal var label: String {
        switch self {
        case .thinking: return "Thinking"
        case .tools: return "Tools"
        }
    }

    internal var icon: String {
        switch self {
        case .thinking: return "brain"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

internal struct ConversationPanel: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    /// The identity the chat presents (harness persona for Centaur, else the
    /// user's Hermes persona) — passed in so this panel doesn't re-derive it.
    internal let persona: Persona
    /// The active skin, resolved by the host so bubbles match the rest of chat.
    internal let skinProvider: ChatSkinProviding
    /// When set (Turns mode), render ONLY this turn's message(s) — the assistant
    /// message with this id and the user prompt that opened it — instead of the
    /// whole transcript. Nil (Scroll mode) shows the full ever-growing thread.
    internal var focusedTurnID: UUID?

    /// Which turns have which blocks peeled into the scroll, keyed by the
    /// assistant message id. Ephemeral per-session UI state — the peeled mirror
    /// is a viewing choice, not persisted content. A peeled block renders as a
    /// card directly beneath its turn's bubble, so it scrolls WITH the turn.
    @State private var peeled: [UUID: Set<PeeledBlockKind>] = [:]

    /// Coalesce token-by-token auto-scroll: bucket the streaming tail so a full
    /// scroll pass fires per ~256 chars, not per delta (mirrors ChatView).
    private var streamTailKey: String {
        guard let last = chatViewModel.messages.last else { return "none" }
        return "\(last.id):\(last.content.count / 256):\(last.isStreaming)"
    }

    /// The messages to render: the whole transcript in Scroll mode, or just the
    /// focused turn's user+assistant pair in Turns mode. The turn is keyed by its
    /// assistant message id (see SessionTurnBuilder); the immediately preceding
    /// user message is its prompt.
    private var visibleMessages: [ChatMessage] {
        let all = chatViewModel.messages
        guard let focusedTurnID,
              let assistantIdx = all.firstIndex(where: { $0.id == focusedTurnID }) else {
            return all
        }
        var start = assistantIdx
        if assistantIdx > 0, all[assistantIdx - 1].role == .user { start = assistantIdx - 1 }
        return Array(all[start...assistantIdx])
    }

    /// Only follow the streaming tail / show the typing indicator when the
    /// conversation is actually showing the live turn — a pinned past turn is
    /// static, so it neither auto-scrolls nor sprouts a "typing" row.
    private var showsLiveTail: Bool {
        focusedTurnID == nil || focusedTurnID == chatViewModel.messages.last?.id
    }

    internal var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let msgs = visibleMessages
                    ForEach(msgs) { message in
                        VStack(alignment: .leading, spacing: 4) {
                            let showTimestamp = ChatView.isLastMessageInGroup(message: message, msgs: msgs)
                            let prepared = ChatView.prepareBubbleMessage(message, showTimestamp: showTimestamp)
                            skinProvider.messageBubble(message: prepared, persona: persona)
                            // Peel affordance + any blocks already peeled into the
                            // scroll for this turn — layered directly under the
                            // bubble so they travel with the turn as you scroll.
                            peelBar(for: message)
                            peeledCards(for: message)
                            // The live turn shows a streaming-status line under its
                            // reply; settled turns show nothing extra (reasoning and
                            // tools already render inside the bubble).
                            streamingStatusUnder(message)
                        }
                        .id(message.id)
                    }
                    // Bottom anchor for auto-scroll.
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .background(Theme.background)
            .onChange(of: streamTailKey) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
            .onChange(of: chatViewModel.messages.count) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
            .onChange(of: focusedTurnID) { _, _ in scrollToTop(proxy) }
            .onAppear { if showsLiveTail { scrollToBottom(proxy, animated: false) } }
        }
    }

    // MARK: - Peel into scroll

    /// Which peelable blocks this turn actually has content for — only assistant
    /// turns, and only kinds with something to show (a thinking trace/reasoning,
    /// or at least one tool call). Empty for user messages and bare replies, so
    /// the peel bar hides itself entirely there.
    private func availableBlocks(for message: ChatMessage) -> [PeeledBlockKind] {
        guard message.role == .assistant else { return [] }
        var kinds: [PeeledBlockKind] = []
        let hasThinking = (message.thinkingTrace?.blocks.isEmpty == false)
            || (message.reasoning?.isEmpty == false)
        if hasThinking { kinds.append(.thinking) }
        if !message.toolCalls.isEmpty { kinds.append(.tools) }
        return kinds
    }

    /// The small "peel to scroll" toggles under a turn's bubble — one chip per
    /// available block. Tapping mirrors that block into the scroll (or pulls it
    /// back). Hidden when the turn has no peelable blocks.
    @ViewBuilder
    private func peelBar(for message: ChatMessage) -> some View {
        let blocks = availableBlocks(for: message)
        if !blocks.isEmpty {
            HStack(spacing: 6) {
                ForEach(blocks, id: \.self) { kind in
                    let isPeeled = peeled[message.id]?.contains(kind) == true
                    Button {
                        togglePeel(kind, for: message.id)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isPeeled ? "arrow.uturn.up" : kind.icon)
                                .font(.system(size: 9, weight: .semibold))
                            Text(isPeeled ? "Return \(kind.label)" : "Peel \(kind.label)")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            isPeeled ? Theme.accent.opacity(0.15) : Theme.surface,
                            in: Capsule()
                        )
                        .foregroundStyle(isPeeled ? Theme.accent : Theme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isPeeled
                          ? "Return this \(kind.label.lowercased()) block into the bubble only"
                          : "Mirror this \(kind.label.lowercased()) block as a card in the scroll")
                }
            }
            .padding(.leading, 4)
        }
    }

    /// The mirrored block cards layered under a turn, for whatever it has peeled.
    /// These are live views of the same `ChatMessage` content the bubble shows —
    /// they update as the turn streams — anchored to the turn so they scroll with
    /// it (not floating tiles over the canvas).
    @ViewBuilder
    private func peeledCards(for message: ChatMessage) -> some View {
        let kinds = peeled[message.id] ?? []
        if !kinds.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                // Stable order regardless of tap order.
                ForEach(PeeledBlockKind.allCases.filter { kinds.contains($0) }, id: \.self) { kind in
                    PeeledBlockCard(kind: kind, message: message) {
                        togglePeel(kind, for: message.id)
                    }
                }
            }
            .padding(.leading, 12)
            .padding(.top, 2)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func togglePeel(_ kind: PeeledBlockKind, for id: UUID) {
        withAnimation(.easeInOut(duration: 0.15)) {
            var set = peeled[id] ?? []
            if set.contains(kind) { set.remove(kind) } else { set.insert(kind) }
            if set.isEmpty { peeled[id] = nil } else { peeled[id] = set }
        }
    }

    /// The streaming-status line shown beneath the live (still-streaming) turn's
    /// reply — the avatar state plus active tool calls, from the active skin.
    /// Settled turns render nothing here: their reasoning and completed tools are
    /// already part of the message bubble.
    @ViewBuilder
    private func streamingStatusUnder(_ message: ChatMessage) -> some View {
        if message.isStreaming {
            skinProvider.streamingPanel(
                state: chatViewModel.avatarState,
                activeToolCalls: chatViewModel.activeToolCalls,
                personaName: persona.name,
                accentColor: persona.accentColor
            )
            .id("conversation-streaming-status")
        }
    }

    private static let bottomAnchor = "conversation-panel-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.15), action)
        } else {
            action()
        }
    }

    /// Page to a newly-focused turn from its top, so a stepped-to turn reads from
    /// the prompt down rather than landing mid-reply. No-op when following the
    /// live tail (that path already pins to the bottom).
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard !showsLiveTail, let firstID = visibleMessages.first?.id else { return }
        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(firstID, anchor: .top) }
    }
}

// MARK: - Peeled Block Card

/// A block (thinking or tools) mirrored out of its bubble into the scroll,
/// anchored under the turn that produced it. It's a live view of the same
/// `ChatMessage` fields the bubble renders — as the turn streams, the card
/// grows with it — value-driven (no timer), so it costs nothing extra per frame.
private struct PeeledBlockCard: View {
    internal let kind: PeeledBlockKind
    internal let message: ChatMessage
    /// Pull the block back into the bubble only (dismiss this mirror).
    internal let onReturn: () -> Void

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.accent.opacity(0.18), lineWidth: 1)
        )
        // A leading accent rail so a peeled card reads as "attached to this turn"
        // rather than a free-floating tile.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.accent.opacity(0.5))
                .frame(width: 2)
                .padding(.vertical, 6)
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kind.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(kind.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Spacer()
            Button(action: onReturn) {
                Image(systemName: "arrow.uturn.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help("Return this block into the bubble only")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .thinking:
            thinkingContent
        case .tools:
            ToolTrailView(
                tools: message.toolCalls,
                reasoning: nil,
                reasoningTokens: nil,
                toolTokens: nil,
                isStreaming: message.isStreaming
            )
        }
    }

    /// The turn's reasoning text — the trace's joined blocks when present, else
    /// the plain reasoning string. Selectable, monospaced, matching the bubble's
    /// reasoning rendering so the mirror reads identically.
    @ViewBuilder
    private var thinkingContent: some View {
        let text = message.thinkingTrace?.fullText ?? message.reasoning ?? ""
        if text.isEmpty {
            Text("No reasoning captured for this turn.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
        } else {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
