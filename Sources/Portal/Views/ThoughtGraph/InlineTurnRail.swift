import SwiftUI

/// The per-turn lens rail: a turn's compact lenses (the flamechart strip, the
/// skills chips) rendered inline UNDER its bubbles. Driven by the SAME panel
/// registry the canvas uses, so a lens defined once shows up here (inline) and,
/// when peeled, on the canvas (panel) — one definition, two placements.
///
/// It renders for EVERY turn, not just the streaming one: paging back to a
/// settled turn replays that turn's timeline from its recorded nodes instead of
/// showing bare bubbles, and the live turn's rail updates as it streams (its
/// context is composed from the live integrators). That's the fix for the two
/// regressions — past turns went blank, and the live activity was a hardcoded,
/// un-targetable block.
///
/// Placement mirrors the shape the streaming turn always used: `.wide` lenses
/// stack in the main column, `.side` lenses sit in a fixed-width trailing column.
/// A lens whose inline builder returns nil for this turn (no nodes, no skills) is
/// dropped, so an empty turn shows no rail at all.
///
/// Anti-beachball: the only timer here is inside the flamechart strip, and it's
/// gated on a still-growing bar — so only the live turn's strip ticks; every
/// settled turn's strip lays out once and then sits static. Many rails, one
/// timer, same as before.
internal struct InlineTurnRail: View {
    internal let context: PanelContext
    internal let lenses: [(kind: PanelKind, lens: InlineLens)]
    /// Dock a lens below the transcript. Nil = rail is read-only (no dock affordance shown).
    internal var onDockKind: ((PanelKind) -> Void)?

    /// The rail lens the pointer is over, so its dock button reveals on hover only.
    @State private var hovered: PanelKind?

    /// One inline lens already built for this turn — kept with its kind so the
    /// peel button knows what to pop onto the canvas.
    private struct BuiltLens: Identifiable {
        internal let kind: PanelKind
        internal let view: AnyView
        internal var id: String { kind.rawValue }
    }

    private func built(_ slot: InlineSlot) -> [BuiltLens] {
        lenses.compactMap { entry in
            guard entry.lens.slot == slot, let view = entry.lens.build(context) else { return nil }
            return BuiltLens(kind: entry.kind, view: view)
        }
    }

    internal var body: some View {
        let wide = built(.wide)
        let side = built(.side)
        if !wide.isEmpty || !side.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                if !wide.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(wide) { cell($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !side.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(side) { cell($0) }
                    }
                    .frame(width: 168)
                }
            }
            .padding(.trailing, 16)
            .padding(.vertical, 2)
            .transition(.opacity)
        }
    }

    /// A single lens with its dock affordance. The dock button is a quiet
    /// arrow-down glyph in the top-trailing corner, shown only when docking is
    /// possible — tapping it pins this lens below the transcript as a persistent
    /// docked section, removing it from the inline rail (no duplication).
    @ViewBuilder
    private func cell(_ lens: BuiltLens) -> some View {
        lens.view
            .overlay(alignment: .topTrailing) {
                if let onDockKind, hovered == lens.kind {
                    Button { onDockKind(lens.kind) } label: {
                        Image(systemName: "arrow.down.to.line")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.secondary)
                            .padding(3)
                            .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dock this lens below the conversation")
                    .transition(.opacity)
                }
            }
            .onHover { inside in
                withAnimation(.easeInOut(duration: 0.12)) { hovered = inside ? lens.kind : nil }
            }
    }
}

/// The live turn's rail. It observes the two graph integrators DIRECTLY — like
/// the old `InlineTurnTimelineLive` — so it (and only it) re-renders as nested
/// subagent/reasoning nodes land, composing the current turn's context from the
/// live tool calls + integrators. Keeping this observation in a small leaf view
/// means the surrounding transcript doesn't re-render on every integrator
/// publish; it repaints on token deltas as it always has.
internal struct LiveInlineTurnRail: View {
    @ObservedObject internal var chatViewModel: ChatViewModel
    @ObservedObject internal var subagentGraph: SubagentGraphIntegrator
    @ObservedObject internal var reasoningGraph: ReasoningGraphIntegrator
    /// The shared flamechart engine — carried in the context for parity with the
    /// canvas, though the inline flamechart strip owns its own layout engine and
    /// ignores it. Passed so a future inline lens that needs it isn't blocked.
    internal let engine: ThoughtGraphLayoutEngine
    internal var selection: Binding<String?>?
    internal let lenses: [(kind: PanelKind, lens: InlineLens)]
    internal var onDockKind: ((PanelKind) -> Void)?

    private var liveNodes: [ThoughtGraphNode] {
        ThoughtGraphLayoutEngine.composeTimeline(
            tools: Array(chatViewModel.activeToolCalls.values).sorted { $0.id < $1.id },
            agentNodes: subagentGraph.agentNodes,
            reasoningNodes: reasoningGraph.reasoningNodes
        )
    }

    internal var body: some View {
        InlineTurnRail(
            context: PanelContext(
                nodes: liveNodes,
                compactions: chatViewModel.currentTurnCompactions,
                skills: chatViewModel.activeSkills,
                isThinking: reasoningGraph.isThinking,
                isStreaming: chatViewModel.isStreaming,
                selection: selection,
                engine: engine,
                onJumpToTool: nil,
                onDock: onDockKind
            ),
            lenses: lenses,
            onDockKind: onDockKind
        )
    }
}
