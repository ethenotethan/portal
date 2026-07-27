import SwiftUI

/// The live chat conversation as a dashboard panel: the real transcript — the
/// same messages, streaming the same way — rendered inside a resizable canvas
/// panel instead of owning the whole screen. It is NOT a snapshot or a copy: it
/// observes the live `ChatViewModel`, so tokens stream in and bubbles grow here
/// exactly as they do in the normal chat.
///
/// Under EACH turn it renders that turn's inline lens rail (`InlineTurnRail`):
/// the compact flamechart strip and skills chips, driven by the shared panel
/// registry. Past turns replay their rail from the recorded transcript; the live
/// turn's rail updates as it streams. Any rail lens can be peeled onto the canvas
/// as its own panel, at which point the registry drops it from the rail — one
/// lens definition, two placements, no duplication. This is what makes the
/// in-chat activity targetable instead of a hardcoded live-only block.
///
/// Timer-free at this level: it re-renders on `ChatViewModel` publishes (new /
/// grown messages, streaming toggles), never on a clock. The only timer is
/// inside the live turn's flamechart strip, gated on a still-growing bar, so the
/// canvas stays at one timer.
internal struct ConversationPanel: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    /// The two per-turn graph integrators, observed by the live rail so it
    /// rebuilds as nested subagent/reasoning nodes land.
    internal var subagentGraph: SubagentGraphIntegrator
    internal var reasoningGraph: ReasoningGraphIntegrator
    /// The identity the chat presents (harness persona for Centaur, else the
    /// user's Hermes persona) — passed in so this panel doesn't re-derive it.
    internal let persona: Persona
    /// The active skin, resolved by the host so bubbles match the rest of chat.
    internal let skinProvider: ChatSkinProviding
    /// When set (Turns mode), render ONLY this turn's message(s) — the assistant
    /// message with this id and the user prompt that opened it — instead of the
    /// whole transcript. Nil (Scroll mode) shows the full ever-growing thread.
    internal var focusedTurnID: UUID?
    /// The shared flamechart engine (carried in each turn's context for parity
    /// with the canvas; the inline strip owns its own layout engine).
    internal var engine: ThoughtGraphLayoutEngine
    /// Cross-highlight selection shared with the canvas lenses.
    internal var selection: Binding<String?>?
    /// The rail lenses to render under each turn — the registry's inline lenses
    /// minus any already peeled onto the canvas, so a peeled lens leaves the rail.
    internal var inlineLenses: [(kind: PanelKind, lens: InlineLens)] = []
    /// Peel a rail lens onto the canvas as its own panel. Nil where there's no
    /// canvas to peel onto (the rail is then read-only).
    internal var onPeel: ((PanelKind) -> Void)?

    // MARK: - Docked panels (attached INSIDE the conversation, below the transcript)

    /// Lenses docked inside this panel — rendered as a persistent section BELOW
    /// the transcript, resizable via a drag divider. Unlike canvas tiles they
    /// travel with the conversation panel and are never external floating views.
    /// The conversation is the ONLY panel that hosts a docked section.
    internal var dockedViews: [(kind: PanelKind, content: AnyView)] = []
    /// Remove a docked lens. Nil when there's nowhere to send the action (read-only).
    internal var onDockedDetach: ((PanelKind) -> Void)?
    /// Height of the docked section (controlled by the parent so it survives re-renders).
    internal var dockedHeight: Binding<CGFloat>?

    /// Coalesce token-by-token auto-scroll: bucket the streaming tail so a full
    /// scroll pass fires per ~256 chars, not per delta (mirrors ChatView).
    private var streamTailKey: String {
        guard let last = chatViewModel.messages.last else { return "none" }
        return "\(last.id):\(last.content.count / 256):\(last.isStreaming)"
    }

    /// Memoized per-turn snapshots for SETTLED turns, keyed so the fold only
    /// re-runs when the settled set actually changes (a new turn, a completed
    /// stream, or a session switch) — never per streaming token. The live turn is
    /// rendered separately from the integrators, so it's excluded here.
    private static let settledTurnMemo = RenderMemo<[UUID: SessionTurn]>(limit: 8)

    private var settledTurnsByID: [UUID: SessionTurn] {
        var msgs = chatViewModel.messages
        if chatViewModel.isStreaming, msgs.last?.isStreaming == true { msgs.removeLast() }
        let key = "\(chatViewModel.currentSessionID ?? "none"):\(msgs.count):\(chatViewModel.isStreaming)"
        return Self.settledTurnMemo.value(for: key) {
            Dictionary(
                SessionTurnBuilder.turns(from: msgs).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
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
        VStack(spacing: 0) {
            // ── The transcript (scroll region) ──
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        let msgs = visibleMessages
                        ForEach(msgs) { message in
                            VStack(alignment: .leading, spacing: 4) {
                                let showTimestamp = ChatView.isLastMessageInGroup(message: message, msgs: msgs)
                                let prepared = ChatView.prepareBubbleMessage(message, showTimestamp: showTimestamp)
                                skinProvider.messageBubble(message: prepared, persona: persona)
                                // The turn's inline lens rail, right under its reply.
                                railUnder(message)
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
                .background(Theme.background)
                .onChange(of: streamTailKey) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
                .onChange(of: chatViewModel.messages.count) { _, _ in if showsLiveTail { scrollToBottom(proxy) } }
                .onChange(of: focusedTurnID) { _, _ in scrollToTop(proxy) }
                .onAppear { if showsLiveTail { scrollToBottom(proxy, animated: false) } }
            }

            // ── Docked panels (attached beneath, part of this view) ──
            // These are lenses the user has chosen to dock INSIDE the
            // conversation rather than as external canvas tiles. They travel
            // with the panel and are the ONLY panels allowed to nest here.
            if !dockedViews.isEmpty, let heightBinding = dockedHeight {
                dockedSection(heightBinding)
            }
        }
    }

    /// The docked-panel section: a drag handle (divider) the user pulls to resize,
    /// then the stacked lens views. Each lens has a detach button (× or ↗) that
    /// calls `onDockedDetach` to promote it back to a canvas tile.
    @ViewBuilder
    private func dockedSection(_ heightBinding: Binding<CGFloat>) -> some View {
        VStack(spacing: 0) {
            // Drag handle
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
            Color.clear
                .frame(height: 10)
                .contentShape(Rectangle())
                .overlay(
                    Capsule()
                        .fill(Theme.tertiary.opacity(0.45))
                        .frame(width: 36, height: 4)
                )
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let newH = max(80, heightBinding.wrappedValue - value.translation.height)
                            heightBinding.wrappedValue = newH
                        }
                )
                .pointerStyleDockedResize()

            // The docked lenses, stacked and clipped to the docked height
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(dockedViews, id: \.kind) { entry in
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Text(entry.kind.rawValue.capitalized)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.secondary)
                                Spacer()
                                if let onDockedDetach {
                                    Button { onDockedDetach(entry.kind) } label: {
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Theme.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Detach to canvas")
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.surface.opacity(0.6))

                            entry.content
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .frame(height: heightBinding.wrappedValue)
            .background(Theme.background)
        }
    }

    /// The lens rail (and, for the live turn, the streaming-status line) shown
    /// beneath `message`. The streaming assistant message gets the live rail wired
    /// to the integrators; a settled turn's assistant message gets a static rail
    /// replayed from its recorded snapshot; every other message gets nothing.
    @ViewBuilder
    private func railUnder(_ message: ChatMessage) -> some View {
        if message.isStreaming {
            skinProvider.streamingPanel(
                state: chatViewModel.avatarState,
                activeToolCalls: chatViewModel.activeToolCalls,
                personaName: persona.name,
                accentColor: persona.accentColor
            )
            .id("conversation-streaming-status")

            LiveInlineTurnRail(
                chatViewModel: chatViewModel,
                subagentGraph: subagentGraph,
                reasoningGraph: reasoningGraph,
                engine: engine,
                selection: selection,
                lenses: inlineLenses,
                onPeel: onPeel
            )
            .id("conversation-live-rail")
        } else if let turn = settledTurnsByID[message.id] {
            InlineTurnRail(
                context: PanelContext(
                    nodes: turn.nodes,
                    compactions: turn.compactions,
                    skills: turn.skills,
                    isThinking: false,   // settled — no heartbeat
                    isStreaming: false,  // …and no growing bars
                    selection: selection,
                    engine: engine,
                    onJumpToTool: nil
                ),
                lenses: inlineLenses,
                onPeel: onPeel
            )
            .id("conversation-rail-\(message.id)")
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

// MARK: - Cursor (macOS only)

private extension View {
    @ViewBuilder
    func pointerStyleDockedResize() -> some View {
        #if os(macOS)
        self.onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        #else
        self
        #endif
    }
}
