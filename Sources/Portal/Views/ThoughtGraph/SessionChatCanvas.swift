#if os(macOS)
import SwiftUI

/// How the canvas drives its per-turn lenses. `scroll` = the live current turn
/// (the ever-growing transcript, panels update as the turn streams); `turns` =
/// page one settled turn at a time (the panels show that turn's snapshot). The
/// conversation panel and session-global panels (artifacts, metrics) behave the
/// same in both — only the per-turn lenses (flamechart/tools/thinking/skills)
/// and the conversation's focus change.
internal enum CanvasDisplayMode: String {
    case scroll
    case turns
}

/// Canvas mode for the live chat (option B): the current session rearranged into
/// resizable, draggable panels — the **conversation itself** as the dominant
/// panel, with the live lenses (flamechart, tools, thinking, skills, files)
/// docked around it. Toggled per session from the chat toolbar; flipping it off
/// returns to the normal full-width transcript. Non-destructive: it's the same
/// `ChatViewModel`, so the conversation streams here exactly as it does normally.
///
/// The message composer is docked at the BOTTOM, outside the canvas, so shrinking
/// or moving the conversation panel can never trap the user's input box.
///
/// Anti-beachball: one owned flamechart engine → the single 30 Hz timer (the
/// flamechart is a singleton kind). Every other panel — including the
/// conversation — is value-driven and re-renders only on data change, so the
/// live canvas costs exactly one timer, same as the normal chat's inline strip.
internal struct SessionChatCanvas: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    @ObservedObject internal var subagentGraph: SubagentGraphIntegrator
    @ObservedObject internal var reasoningGraph: ReasoningGraphIntegrator
    /// Chat identity + skin, resolved by the host so the conversation panel
    /// matches the rest of the app.
    internal let persona: Persona
    internal let skinProvider: ChatSkinProviding
    /// Gateway client for the pinned session-usage badge (cumulative tokens /
    /// cost / context %). Session-global metrics that persist across turns.
    internal let client: GatewayClient
    /// Text-to-speech, folded into the canvas toolbar alongside the other
    /// session-global chrome (usage, response style, export) now that the canvas
    /// IS the chat and owns the whole toolbar.
    @EnvironmentObject internal var ttsService: TTSService
    /// Composer focus wiring, owned by ChatView (so canvas clicks can restore
    /// first-responder just like the normal transcript).
    internal var isInputFocused: FocusState<Bool>.Binding
    @Binding internal var inputFieldRef: FocusableTextView?

    @StateObject private var engine = ThoughtGraphLayoutEngine()
    @State private var layout = DashboardLayout()
    @State private var didLoadLayout = false
    @State private var showAddPalette = false
    @State private var canvasBounds: CGSize = .zero
    /// Lenses docked INSIDE the conversation panel (attached beneath the
    /// transcript). These kinds are removed from the canvas tiles — a docked
    /// lens is part of the conversation, not an external floating panel.
    @State private var dockedKinds: [PanelKind] = []
    /// Height of the docked section inside the conversation panel.
    @State private var dockedSectionHeight: CGFloat = 220
    /// Edit vs. use. Starts in **use** mode: the canvas is immediately usable
    /// (scroll the chat, read the lenses) and only becomes rearrangeable when the
    /// user taps Edit. This is the "go into edit mode, make changes, save, then
    /// just use it" model — and the reason panels no longer feel grabby.
    @State private var isEditing = false
    /// Show each panel's title bar, or hide all of them for a chrome-free canvas
    /// that's just the panels' content. Persisted so the canvas reopens the way
    /// it was left. Defaults OFF: the canvas now IS the chat, and its default is
    /// a single conversation panel — a "Conversation" header over the only thing
    /// on screen is pure noise. Turn it on once you've added lens panels worth
    /// labelling.
    @AppStorage("sessionChatCanvasShowsTitleBars") private var showsTitleBars = false
    /// Collapse the whole canvas toolbar to a slim strip. Defaults collapsed:
    /// the toolbar carries a lot of chrome (reset, session graph, usage,
    /// response style, export, TTS, edit) that adds cognitive load to everyday
    /// chatting, so the canvas opens clean — just the conversation and composer —
    /// and the bar expands on demand. Persisted so it reopens the way it was left.
    @AppStorage("sessionChatCanvasToolbarCollapsed") private var toolbarCollapsed = true
    /// Scroll (the ever-growing transcript, live current-turn lenses) vs. Turns
    /// (page one turn at a time; the per-turn lenses show THAT turn). Session-
    /// global panels — artifacts and the metrics badge — persist across turns
    /// either way. Ephemeral per-session UI state, like `isEditing`.
    @State private var displayMode: CanvasDisplayMode = .scroll
    /// Which turn is shown in Turns mode. Nil follows the latest turn (tail-
    /// follow): sending a message advances here so you watch your new turn
    /// stream, and stepping back off the last turn pins an explicit id.
    @State private var selectedTurnID: UUID?
    /// Cross-highlight shared between the flamechart, tools, and files panels.
    @State private var selectedNodeID: String?
    private let registry = PanelRegistry.chatCanvas

    /// The session split into turns (one assistant message = one turn), rebuilt
    /// from the live transcript. Empty until the first turn completes enough to
    /// graph.
    private var turns: [SessionTurn] {
        SessionTurnBuilder.turns(from: chatViewModel.messages)
    }

    /// The turn Turns mode is showing: the explicitly-selected one, else the
    /// latest (tail-follow).
    private var selectedTurn: SessionTurn? {
        turns.first { $0.id == selectedTurnID } ?? turns.last
    }

    /// 1-based position of the selected turn, for the "Turn N of M" counter.
    private var selectedTurnNumber: Int {
        guard let selectedTurn else { return 0 }
        return (turns.firstIndex { $0.id == selectedTurn.id } ?? 0) + 1
    }

    /// Export scope for the toolbar's Export menu. In Turns mode it's the turn on
    /// screen (its user prompt + assistant reply), so export offers "this turn"
    /// beside "whole session"; nil in Scroll mode → whole-session export only.
    /// The turn is the user+assistant pair keyed by the assistant message id —
    /// the same slice the conversation panel shows in Turns mode.
    private var turnExportScope: TurnExportScope? {
        guard displayMode == .turns, let selectedTurn else { return nil }
        let all = chatViewModel.messages
        guard let assistantIdx = all.firstIndex(where: { $0.id == selectedTurn.id }) else { return nil }
        var start = assistantIdx
        if assistantIdx > 0, all[assistantIdx - 1].role == .user { start = assistantIdx - 1 }
        return TurnExportScope(
            label: "Turn \(selectedTurnNumber)",
            messages: Array(all[start...assistantIdx])
        )
    }

    /// The current turn's live nodes, composed from the active tool calls and
    /// the two graph integrators — the same composition the inline strip and the
    /// session-graph sheet use, so the canvas lenses agree with them.
    private var liveNodes: [ThoughtGraphNode] {
        ThoughtGraphLayoutEngine.composeTimeline(
            tools: Array(chatViewModel.activeToolCalls.values).sorted { $0.id < $1.id },
            agentNodes: subagentGraph.agentNodes,
            reasoningNodes: reasoningGraph.reasoningNodes
        )
    }

    /// The context the per-turn lenses render. In **scroll** mode it's the live
    /// current turn (streaming); in **turns** mode it's the selected turn's
    /// settled snapshot, so the flamechart/tools/thinking rewind with the pager
    /// while the conversation, artifacts, and metrics stay put.
    private var panelContext: PanelContext {
        if displayMode == .turns, let turn = selectedTurn {
            return PanelContext(
                nodes: turn.nodes,
                compactions: turn.compactions,
                skills: turn.skills,
                isThinking: false,       // a settled past turn isn't thinking
                isStreaming: false,      // …and isn't streaming — no growing bars
                selection: $selectedNodeID,
                engine: engine,
                onJumpToTool: nil
            )
        }
        return PanelContext(
            nodes: liveNodes,
            compactions: chatViewModel.currentTurnCompactions,
            skills: chatViewModel.activeSkills,
            isThinking: reasoningGraph.isThinking,
            isStreaming: chatViewModel.isStreaming,
            selection: $selectedNodeID,
            engine: engine,
            onJumpToTool: nil
        )
    }

    internal var body: some View {
        VStack(spacing: 0) {
            if toolbarCollapsed {
                collapsedToolbar
            } else {
                toolbar
            }
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                DashboardCanvasView(
                    layout: $layout,
                    isEditing: isEditing,
                    showsTitleBars: showsTitleBars,
                    title: { registry.title(for: $0) },
                    icon: { registry.icon(for: $0) },
                    onLayoutCommitted: { layout.store(key: DashboardLayout.chatCanvasKey) },
                    content: { panel in panelContent(panel) }
                )
                .onAppear {
                    canvasBounds = geo.size
                    loadLayoutIfNeeded(bounds: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in canvasBounds = newSize }
            }

            Divider().overlay(Theme.border)
            // Composer docked outside the canvas — always reachable.
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    /// Render a panel's content: the conversation is host-supplied (the live
    /// transcript); every other kind is built by the registry from the live
    /// context.
    private func panelContent(_ panel: DashboardPanel) -> AnyView {
        if panel.kind == .conversation {
            let docked = dockedKinds.map { kind -> (kind: PanelKind, content: AnyView) in
                let ctx = panelContext
                let view = registry.content(for: kind, context: ctx)
                return (kind, view)
            }
            return AnyView(
                ConversationPanel(
                    chatViewModel: chatViewModel,
                    subagentGraph: subagentGraph,
                    reasoningGraph: reasoningGraph,
                    persona: persona,
                    skinProvider: skinProvider,
                    // Turns mode isolates the selected turn; Scroll shows it all.
                    focusedTurnID: displayMode == .turns ? selectedTurn?.id : nil,
                    engine: engine,
                    selection: $selectedNodeID,
                    // Each turn's inline rail shows the registry's inline lenses
                    // MINUS any already docked beneath the transcript — a docked
                    // lens leaves the rail, never shown twice.
                    inlineLenses: registry.inlineLenses(peeled: dockedKinds),
                    onDockKind: dockLens,
                    dockedViews: docked,
                    onDockedDetach: detachFromDock,
                    dockedHeight: $dockedSectionHeight
                )
            )
        }
        // Artifacts are session-global (ArtifactStore.shared), host-rendered so
        // they persist across scroll and turn paging — not built from the
        // per-turn PanelContext.
        if panel.kind == .artifacts {
            return AnyView(ArtifactsPanel())
        }
        // Session Graph — the macro all-turns plot, host-rendered (needs both
        // integrators + jump-to-tool). Docked in-canvas rather than a sheet.
        if panel.kind == .sessionGraph {
            return AnyView(
                SessionGraphPane(
                    chatViewModel: chatViewModel,
                    subagentGraph: subagentGraph,
                    reasoningGraph: reasoningGraph,
                    onJumpToTool: { selectedNodeID = $0 }
                )
            )
        }
        return registry.content(for: panel.kind, context: panelContext)
    }

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: 10) {
            // Reset the arrangement back to the plain single-conversation chat —
            // the canvas IS the chat now, so there's nothing to "exit" to; this
            // is the one-click way back to the default view. Non-destructive: the
            // conversation is untouched, only the panel layout resets.
            Button(action: resetToDefault) {
                Label("Reset to default view", systemImage: "rectangle.arrowtriangle.2.inward")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .help("Reset to the default view — a single full-width conversation")

            // Session Graph opener — reveals the all-turns graph as an IN-CANVAS
            // panel (docked beside the conversation), not a fullscreen sheet. If
            // it's already on the canvas this brings it to front instead of
            // adding a duplicate (it's a singleton kind).
            Button(action: revealSessionGraph) {
                Label("Session Graph", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasSessionGraphPanel ? Theme.accent : Theme.secondary)
            .help("Show the all-turns Session Graph as a panel")

            // Session-global metrics: cumulative tokens / cost / context %.
            // Pinned here so it persists across turns and scroll — it never
            // rewinds with the per-turn pager.
            SessionUsageBadge(chatViewModel: chatViewModel, client: client)

            Spacer()

            // Scroll ↔ Turns, and (in Turns) the prev/next pager. Centered so it
            // reads as the canvas's primary navigation.
            displayModeControls

            Spacer()

            // ── Session-global chrome, folded in from the old chat header now
            // that the canvas owns the whole toolbar: response style, export, TTS.
            responseStyleMenu

            // Export — turn-aware: in Turns mode it also offers the turn on
            // screen; in Scroll mode it's whole-session, as before.
            SessionExportMenu(assistantName: persona.name, turnScope: turnExportScope)
                .padding(.horizontal, 2)

            ttsToggle

            // Edit-only: adding a panel is an edit, so it lives behind Edit mode.
            if isEditing {
                Button {
                    showAddPalette.toggle()
                } label: {
                    Label("Add panel", systemImage: "plus.rectangle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .popover(isPresented: $showAddPalette, arrowEdge: .bottom) { addPalette }
            }

            // Header toggle: hide/show every panel's title bar for a chrome-free
            // canvas. Available in both modes — it's a viewing preference, not an edit.
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showsTitleBars.toggle() }
            } label: {
                Image(systemName: showsTitleBars ? "menubar.rectangle" : "rectangle")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(showsTitleBars ? Theme.secondary : Theme.accent)
            .help(showsTitleBars ? "Hide panel headers" : "Show panel headers")

            // The mode toggle: Edit ↔ Done. Done persists the arrangement and
            // locks the canvas for use.
            Button {
                if isEditing {
                    layout.store(key: DashboardLayout.chatCanvasKey)
                    showAddPalette = false
                }
                withAnimation(.easeInOut(duration: 0.15)) { isEditing.toggle() }
            } label: {
                Label(isEditing ? "Done" : "Edit",
                      systemImage: isEditing ? "checkmark" : "slider.horizontal.3")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isEditing ? Theme.accent : Theme.secondary)
            .help(isEditing ? "Save this arrangement and lock the canvas" : "Rearrange the panels")

            // Collapse the toolbar away to its slim strip — the everyday state.
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { toolbarCollapsed = true }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.tertiary)
            .help("Collapse the toolbar")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface.opacity(0.5))
    }

    /// The everyday state: the toolbar folded to a slim strip so the canvas is
    /// just the conversation and composer. A single expander opens the full bar;
    /// while collapsed we still surface the two things worth a glance without
    /// expanding — the Turn N of M counter when paging, and a streaming dot — but
    /// nothing clickable-yet-disabled, so a fresh session shows only the expander.
    private var collapsedToolbar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { toolbarCollapsed = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show the canvas toolbar")

            if displayMode == .turns, !turns.isEmpty {
                Text("Turn \(selectedTurnNumber) of \(turns.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
                    .monospacedDigit()
            }

            Spacer()

            if chatViewModel.isStreaming {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .help("Streaming")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(Theme.surface.opacity(0.35))
    }

    /// Reset the canvas to its default expression: a single full-width
    /// conversation, headers off, following the live tail in Scroll mode. The
    /// conversation itself is never touched — only the panel arrangement.
    private func resetToDefault() {
        withAnimation(.easeInOut(duration: 0.18)) {
            layout = DashboardLayout.seededChatCanvas(for: canvasBounds)
            showsTitleBars = false
            displayMode = .scroll
            selectedTurnID = nil
            isEditing = false
        }
        layout.store(key: DashboardLayout.chatCanvasKey)
    }

    /// Response style (deep map / balanced / direct) — a SESSION-global setting:
    /// it steers how every following turn is answered, so it stays in the toolbar
    /// rather than rewinding with the per-turn pager. Shown only when the backend
    /// supports it, exactly as the old chat header did.
    @ViewBuilder
    private var responseStyleMenu: some View {
        if chatViewModel.backendCapabilities.supportsResponseStyles {
            Menu {
                ForEach(ResponseStyle.allCases) { style in
                    Button {
                        chatViewModel.setResponseStyle(style)
                    } label: {
                        if style == chatViewModel.responseStyle {
                            Label(style.label, systemImage: "checkmark")
                        } else {
                            Text(style.label)
                        }
                    }
                    .help(style.help)
                }
            } label: {
                Label(chatViewModel.responseStyle.label, systemImage: chatViewModel.responseStyle.icon)
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Theme.secondary)
            .help("Response style: \(chatViewModel.responseStyle.help). Use /brief for a one-off direct answer.")
        }
    }

    private var ttsToggle: some View {
        Button {
            ttsService.toggle()
        } label: {
            Image(systemName: ttsService.isEnabled ? "speaker.wave.3.fill" : "speaker.slash")
                .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(ttsService.isEnabled ? Theme.accent : Theme.secondary)
        .help(ttsService.isEnabled ? "Text-to-speech enabled" : "Text-to-speech disabled")
    }

    /// Scroll ↔ Turns switch plus, in Turns mode, the prev/next pager and the
    /// "Turn N of M" counter. Disabled until there's at least one turn to page.
    @ViewBuilder
    private var displayModeControls: some View {
        HStack(spacing: 8) {
            Picker("", selection: $displayMode) {
                Label("Scroll", systemImage: "scroll").tag(CanvasDisplayMode.scroll)
                Label("Turns", systemImage: "square.stack").tag(CanvasDisplayMode.turns)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(turns.isEmpty)
            .help(turns.isEmpty
                  ? "Turn-by-turn is available once the first turn completes"
                  : "Scroll the whole thread, or page one turn at a time")

            if displayMode == .turns {
                HStack(spacing: 4) {
                    Button { step(-1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedTurnNumber <= 1)
                    .help("Previous turn")

                    Text(turns.isEmpty ? "—" : "Turn \(selectedTurnNumber) of \(turns.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 84)

                    Button { step(1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .disabled(selectedTurnNumber >= turns.count)
                    .help("Next turn")
                }
                .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Move the selected turn by `delta` (clamped), pinning an explicit id so the
    /// pager stops following the tail.
    private func step(_ delta: Int) {
        guard !turns.isEmpty else { return }
        let current = max(1, selectedTurnNumber)
        let next = min(max(1, current + delta), turns.count)
        selectedTurnID = turns[next - 1].id
    }

    private var addPalette: some View {
        let presentOnCanvas = layout.panels.map(\.kind)
        let options = registry.addableDescriptors(present: presentOnCanvas)
        // Dockable: non-singleton lenses from the standard set that aren't
        // already docked or a conversation/artifacts/sessionGraph panel
        // (those are session-global and must live on the canvas).
        let nonDockable: Set<PanelKind> = [.conversation, .artifacts, .sessionGraph]
        let dockOptions = options.filter { !nonDockable.contains($0.kind) && !dockedKinds.contains($0.kind) }
        return VStack(alignment: .leading, spacing: 2) {
            Text("Add to canvas")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 4)
            if options.isEmpty && dockOptions.isEmpty {
                Text("Every panel is already visible.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            } else {
                ForEach(options) { descriptor in
                    Button {
                        addPanel(descriptor)
                        showAddPalette = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: descriptor.icon)
                                .frame(width: 16)
                                .foregroundStyle(Theme.accent)
                            Text(descriptor.title)
                                .foregroundStyle(Theme.primary)
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            // ── Dock inside conversation ──
            // The conversation panel is the only one that hosts nested panels,
            // so docking is a separate section — visually distinct from "add to canvas".
            if !dockOptions.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Dock inside conversation")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                    .padding(.bottom, 2)
                ForEach(dockOptions) { descriptor in
                    Button {
                        dockLens(descriptor.kind)
                        showAddPalette = false
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: descriptor.icon)
                                .frame(width: 16)
                                .foregroundStyle(Theme.tertiary)
                            Text(descriptor.title)
                                .foregroundStyle(Theme.primary)
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.tertiary)
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if chatViewModel.pendingApproval != nil {
                ApprovalBanner()
                    .environmentObject(chatViewModel)
                    .padding(.horizontal, 24)
            }
            if chatViewModel.pendingClarify != nil {
                ClarifyBanner()
                    .environmentObject(chatViewModel)
                    .padding(.horizontal, 24)
            }
            ChatInputBar(isFocused: isInputFocused, inputFieldRef: $inputFieldRef)
                .environmentObject(chatViewModel)
                .frame(maxWidth: 840, alignment: .center)
                .id(chatViewModel.currentSessionID ?? "no-session")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.surface.opacity(0.4))
    }

    // MARK: - Layout lifecycle

    private func loadLayoutIfNeeded(bounds: CGSize) {
        guard !didLoadLayout else { return }
        didLoadLayout = true
        let loaded = DashboardLayout.loadStored(key: DashboardLayout.chatCanvasKey)
            ?? DashboardLayout.seededChatCanvas(for: bounds)
        layout = loaded.clamped(to: bounds)
    }

    private func addPanel(_ descriptor: PanelDescriptor) {
        addPanel(kind: descriptor.kind)
    }

    /// Add a panel of `kind` in the first vacant slot (or a sensible default
    /// size), bring it to front, and persist. Shared by the add-palette and the
    /// toolbar's reveal actions.
    private func addPanel(kind: PanelKind) {
        let size = CGSize(
            width: min(360, max(DashboardPanel.minSize.width, canvasBounds.width * 0.4)),
            height: min(300, max(DashboardPanel.minSize.height, canvasBounds.height * 0.5))
        )
        // Drop it into the first vacant slot so it doesn't land on top of an
        // existing panel (the no-overlap rule applies to new panels too).
        let frame = PanelResizeMath.vacantSlot(
            size: size,
            others: layout.panels.map(\.frame),
            bounds: canvasBounds
        )
        let panel = DashboardPanel(kind: kind, frame: frame).clamped(to: canvasBounds)
        layout.panels.append(panel)
        layout.bringToFront(panel.id)
        layout.store(key: DashboardLayout.chatCanvasKey)
    }

    /// Peel a rail lens onto the canvas as its own panel. Adds a panel of that
    /// kind (in the first vacant slot) if it isn't already present, else raises
    /// the existing one. Because the conversation's rail is fed
    /// `inlineLenses(peeled:)`, the lens leaves the rail the moment its panel
    /// exists — the rail↔canvas move is driven entirely by what's on the canvas,
    /// so there's no separate "peeled" state to keep in sync.
    private func peelLens(_ kind: PanelKind) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if let existing = layout.panels.first(where: { $0.kind == kind }) {
                layout.bringToFront(existing.id)
                layout.store(key: DashboardLayout.chatCanvasKey)
            } else {
                addPanel(kind: kind)
            }
        }
    }

    /// Dock a lens INSIDE the conversation panel (attached beneath the transcript)
    /// rather than as an external canvas tile. Removes any existing canvas tile for
    /// that kind so it doesn't exist in both places.
    internal func dockLens(_ kind: PanelKind) {
        withAnimation(.easeInOut(duration: 0.18)) {
            layout.remove(kind)
            if !dockedKinds.contains(kind) { dockedKinds.append(kind) }
            layout.store(key: DashboardLayout.chatCanvasKey)
        }
    }

    /// Detach a docked lens, promoting it back onto the canvas as a regular tile.
    private func detachFromDock(_ kind: PanelKind) {
        withAnimation(.easeInOut(duration: 0.18)) {
            dockedKinds.removeAll { $0 == kind }
            addPanel(kind: kind)
        }
    }

    /// True when the Session Graph tile is already on the canvas — the toolbar
    /// button highlights and, on tap, brings it to front rather than duplicating.
    private var hasSessionGraphPanel: Bool {
        layout.panels.contains { $0.kind == .sessionGraph }
    }

    /// Reveal the Session Graph as an in-canvas panel: bring it to front if it's
    /// already there, else add it. Replaces the old fullscreen-sheet opener.
    private func revealSessionGraph() {
        withAnimation(.easeInOut(duration: 0.18)) {
            if let existing = layout.panels.first(where: { $0.kind == .sessionGraph }) {
                layout.bringToFront(existing.id)
                layout.store(key: DashboardLayout.chatCanvasKey)
            } else {
                addPanel(kind: .sessionGraph)
            }
        }
    }
}
#endif
