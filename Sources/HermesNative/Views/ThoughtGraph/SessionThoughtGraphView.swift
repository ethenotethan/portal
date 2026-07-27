import SwiftUI

// MARK: - Turn model

/// One turn's worth of thought-graph data, reconstructed from a persisted
/// assistant `ChatMessage`. A session is an ensemble of these — the per-turn
/// flamechart, replayable across the whole conversation.
internal struct SessionTurn: Identifiable {
    internal let id: UUID
    /// 1-based turn number for display.
    internal let index: Int
    /// The user prompt that opened this turn, trimmed for the rail label.
    internal let prompt: String
    /// Assistant reply preview, for the rail subtitle.
    internal let replyPreview: String
    /// Nodes composed for this turn: tool bars (always) + subagent lanes and
    /// reasoning beats (present when the turn carried a graph snapshot).
    internal let nodes: [ThoughtGraphNode]
    /// Context-compaction folds during this turn, drawn as full-height rules
    /// across the flamechart. Empty for turns with no compaction (the common
    /// case) or persisted before compaction capture existed.
    internal let compactions: [CompactionMarker]
    /// Skills active during this turn ("what"). Live-only for now — the current
    /// turn carries `ChatViewModel.activeSkills`; past turns are empty because
    /// skills aren't persisted per-turn yet (the skills panel shows an honest
    /// "not recorded" state rather than inventing them).
    internal let skills: [SkillInfo]
    /// Tool-call count, for the rail badge.
    internal let toolCount: Int
    /// Whether full depth (reasoning/subagents) is available, vs tool-only —
    /// true for turns recorded before graph-snapshot capture or resumed from
    /// gateway history without timing.
    internal let toolsOnly: Bool

    internal var title: String {
        prompt.isEmpty ? "Turn \(index)" : prompt
    }
}

internal enum SessionTurnBuilder {
    /// Split a transcript into per-turn graphs. Each assistant message is one
    /// turn; the nearest preceding user message supplies the prompt label.
    /// MainActor-isolated because `composeTimeline` is (it lives on the engine).
    @MainActor
    internal static func turns(from messages: [ChatMessage]) -> [SessionTurn] {
        var turns: [SessionTurn] = []
        var pendingPrompt = ""
        var turnIndex = 0

        for message in messages {
            switch message.role {
            case .user:
                pendingPrompt = message.content
            case .assistant:
                // Skip empty assistant turns (no tools, no reply) — nothing to graph.
                guard !message.toolCalls.isEmpty
                    || message.graphSnapshot?.isEmpty == false
                    || !message.content.isEmpty else { continue }
                turnIndex += 1
                let snapshot = message.graphSnapshot
                let nodes = ThoughtGraphLayoutEngine.composeTimeline(
                    tools: message.toolCalls.sorted { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) },
                    agentNodes: snapshot?.agentNodes ?? [],
                    reasoningNodes: snapshot?.reasoningNodes ?? []
                )
                turns.append(SessionTurn(
                    id: message.id,
                    index: turnIndex,
                    prompt: pendingPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    replyPreview: String(message.content.prefix(80)),
                    nodes: nodes,
                    compactions: snapshot?.compactions ?? [],
                    skills: [],
                    toolCount: message.toolCalls.count,
                    toolsOnly: snapshot == nil || snapshot?.isEmpty == true
                ))
                pendingPrompt = ""
            }
        }
        return turns
    }
}

// MARK: - Session thought graph

/// The per-session Agent Thought Graph: a session is an ensemble of per-turn
/// flamecharts. A left rail lists every turn; selecting one drives a composable
/// **dashboard** on the right, where the user drags and resizes panels (the
/// flamechart, thinking beats, running tools, skills, files) to taste.
///
/// The flamechart is the ONLY panel that runs a 30 Hz redraw timer, so it's a
/// singleton kind — at most one on the canvas — keeping the whole dashboard at
/// today's one-timer cost. Every other panel is a value-driven list/tree that
/// re-renders only on data change, so composing many is beachball-free. Paging
/// turns via the rail re-seeds each panel's per-turn state.
internal struct SessionThoughtGraphView: View {
    internal let turns: [SessionTurn]
    /// The local reasoning model is summarizing right now (heartbeat).
    internal var isThinking: Bool = false
    /// Newest turn is selected by default (most recent activity).
    @State private var selectedTurnID: UUID?
    /// Selection shared between the timeline (when) and the file tree (where):
    /// select a bar → its file highlights; tap a file → its bar lights.
    @State private var selectedNodeID: String?
    /// The one flamechart engine, owned here and injected into the (singleton)
    /// flamechart panel — never one-per-panel (the anti-beachball rule).
    @StateObject private var engine = ThoughtGraphLayoutEngine()

    // MARK: Dashboard composition state

    /// The user's panel arrangement — one personal layout, applied to whatever
    /// turn the rail has selected. Loaded once, persisted on every drag/resize.
    @State private var layout = DashboardLayout()
    @State private var didLoadLayout = false
    @State private var showAddPalette = false
    /// Last measured canvas size, so "reset layout" can re-tile for the real
    /// viewport even though the reset button has no geometry of its own.
    @State private var canvasBounds: CGSize = .zero
    /// Edit vs. use — same model as the live chat canvas. Starts in use mode so
    /// the dashboard is immediately readable and only becomes rearrangeable on
    /// Edit; panels don't feel grabby while you're just inspecting a turn.
    @State private var isEditing = false
    private let registry = PanelRegistry.standard

    internal var onJumpToTool: ((String) -> Void)?

    private var selectedTurn: SessionTurn? {
        turns.first { $0.id == selectedTurnID } ?? turns.last
    }

    /// Build the render inputs for a panel from the currently-selected turn.
    /// The heartbeat only pulses on the live (last) turn — past turns are settled.
    private func panelContext(for panel: DashboardPanel) -> PanelContext {
        let turn = selectedTurn
        return PanelContext(
            nodes: turn?.nodes ?? [],
            compactions: turn?.compactions ?? [],
            skills: turn?.skills ?? [],
            isThinking: isThinking && turn?.id == turns.last?.id,
            selection: $selectedNodeID,
            engine: engine,
            onJumpToTool: onJumpToTool
        )
    }

    internal var body: some View {
        if turns.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                turnRail
                    .frame(width: 200)
                Divider().overlay(Theme.border)
                dashboard
            }
            .onAppear { if selectedTurnID == nil { selectedTurnID = turns.last?.id } }
            // Clear cross-highlight when switching turns (ids don't carry over).
            .onChange(of: selectedTurnID) { _, _ in selectedNodeID = nil }
        }
    }

    // MARK: - Dashboard

    /// The composable canvas: a toolbar (add-panel + reset) over a free-form
    /// `DashboardCanvasView`. Panels re-key on the selected turn so the
    /// flamechart engine re-seeds when the user pages the rail.
    private var dashboard: some View {
        VStack(spacing: 0) {
            dashboardToolbar
            Divider().overlay(Theme.border)
            GeometryReader { geo in
                DashboardCanvasView(
                    layout: $layout,
                    isEditing: isEditing,
                    title: { registry.title(for: $0) },
                    icon: { registry.icon(for: $0) },
                    onLayoutCommitted: { layout.store() },
                    content: { panel in
                        AnyView(
                            registry.content(for: panel.kind, context: panelContext(for: panel))
                                // Re-seed a panel's inner state (e.g. the
                                // flamechart engine) when the turn changes.
                                .id(selectedTurn?.id)
                        )
                    }
                )
                .onAppear {
                    canvasBounds = geo.size
                    loadLayoutIfNeeded(bounds: geo.size)
                }
                .onChange(of: geo.size) { _, newSize in canvasBounds = newSize }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dashboardToolbar: some View {
        HStack(spacing: 10) {
            Text(selectedTurn.map { "Turn \($0.index)" } ?? "Dashboard")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.secondary)
            Text(isEditing
                 ? "drag a panel to move · drag an edge or corner to resize"
                 : "using the dashboard — tap Edit to rearrange")
                .font(.system(size: 10))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                .layoutPriority(-1)
            Spacer()
            if isEditing {
                Button {
                    showAddPalette.toggle()
                } label: {
                    Label("Add panel", systemImage: "plus.rectangle")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .popover(isPresented: $showAddPalette, arrowEdge: .bottom) {
                    addPalette
                }
                Button {
                    layout = DashboardLayout.seededDefault(for: canvasBounds)
                    layout.store()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.tertiary)
                .help("Reset to the default layout")
            }
            Button {
                if isEditing {
                    layout.store()
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
            .help(isEditing ? "Save this arrangement and lock the dashboard" : "Rearrange the panels")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Theme.surface.opacity(0.5))
    }

    /// The add-panel palette: every registered kind not already blocked (a
    /// singleton that's present). This is where custom sub-views surface — a
    /// registered plugin appears here automatically.
    private var addPalette: some View {
        let present = layout.panels.map(\.kind)
        let options = registry.addableDescriptors(present: present)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Add a panel")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.bottom, 4)
            if options.isEmpty {
                Text("Every panel is already on the canvas.")
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
        }
        .padding(12)
        .frame(width: 200)
    }

    // MARK: Layout lifecycle

    /// Load the saved layout once the canvas has a real size — or seed the
    /// default tiling on first run — clamping either into the viewport.
    private func loadLayoutIfNeeded(bounds: CGSize) {
        guard !didLoadLayout else { return }
        didLoadLayout = true
        let loaded = DashboardLayout.loadStored() ?? DashboardLayout.seededDefault(for: bounds)
        layout = loaded.clamped(to: bounds)
    }

    /// Drop a new panel into the first vacant slot so it doesn't overlap an
    /// existing one (the no-overlap rule applies to new panels too).
    private func addPanel(_ descriptor: PanelDescriptor) {
        let size = CGSize(width: min(360, max(DashboardPanel.minSize.width, canvasBounds.width * 0.4)),
                          height: min(300, max(DashboardPanel.minSize.height, canvasBounds.height * 0.5)))
        let frame = PanelResizeMath.vacantSlot(
            size: size,
            others: layout.panels.map(\.frame),
            bounds: canvasBounds
        )
        let panel = DashboardPanel(kind: descriptor.kind, frame: frame).clamped(to: canvasBounds)
        layout.panels.append(panel)
        layout.store()
    }

    private var turnRail: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(turns) { turn in
                    turnRow(turn)
                }
            }
            .padding(10)
        }
        .background(Theme.surface.opacity(0.4))
    }

    private func turnRow(_ turn: SessionTurn) -> some View {
        let isSelected = turn.id == (selectedTurn?.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Turn \(turn.index)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.primary)
                Spacer()
                Text("\(turn.toolCount)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                if turn.toolsOnly {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.tertiary)
                        .help("Tool calls only — full depth wasn't recorded for this turn")
                }
            }
            Text(turn.title)
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Theme.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { selectedTurnID = turn.id }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiary)
            Text("No activity in this session")
                .font(.headline)
                .foregroundStyle(Theme.secondary)
            Text("Tool calls and subagent activity appear here once the agent works a turn.")
                .font(.caption)
                .foregroundStyle(Theme.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
