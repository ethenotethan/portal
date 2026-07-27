import SwiftUI

/// Everything a dashboard panel might need to render one turn. Passed to every
/// panel builder so a custom sub-view has the same material the built-ins do:
/// the turn's composed nodes, its compaction folds and skills, the shared
/// cross-highlight selection, the single flamechart engine, the live-thinking
/// flag, and the jump-to-tool callback. A new panel type consumes whatever
/// subset it needs and ignores the rest.
internal struct PanelContext {
    internal let nodes: [ThoughtGraphNode]
    internal let compactions: [CompactionMarker]
    internal let skills: [SkillInfo]
    internal let isThinking: Bool
    /// The turn is streaming right now — drives the flamechart's growing right
    /// edge and live rescale. `false` for settled past turns (the dashboard);
    /// the live chat canvas passes the model's streaming flag.
    internal var isStreaming: Bool = false
    /// Shared timeline↔filetree↔tools highlight. Nil when the host isn't
    /// coordinating a selection.
    internal let selection: Binding<String?>?
    /// The ONE flamechart engine, owned by the dashboard and injected into the
    /// (singleton) flamechart panel — never created per-panel.
    internal let engine: ThoughtGraphLayoutEngine
    internal let onJumpToTool: ((String) -> Void)?
}

/// Where a lens sits when it renders inline in the conversation feed (the rail
/// under each turn), as opposed to peeled out into a full canvas panel. `.wide`
/// lenses (the time-plot flamechart) fill the rail's width; `.side` lenses (the
/// skills chips) sit in a fixed-width trailing column beside them — the same
/// two-column shape the streaming turn always showed, now generalized so a new
/// lens picks its slot instead of the layout being hardcoded.
internal enum InlineSlot {
    case wide
    case side
}

/// A lens's **inline** placement: how it renders compactly in the per-turn rail.
/// The builder returns `nil` when this turn has nothing for the lens (no nodes,
/// no skills) so the rail simply omits it — an empty turn shows no rail, exactly
/// as the old live-only strip rendered nothing until there was activity.
internal struct InlineLens {
    internal let slot: InlineSlot
    internal let build: (PanelContext) -> AnyView?

    internal init(slot: InlineSlot, build: @escaping (PanelContext) -> AnyView?) {
        self.slot = slot
        self.build = build
    }
}

/// One entry in the panel catalog: what a kind is called, its icon, whether the
/// dashboard allows more than one on the canvas at once, and how to build its
/// content view from a `PanelContext` — in BOTH placements a lens can take: the
/// full canvas `build`, and the compact `inline` rail form. A lens "plugs in
/// once" here and is then available both under a turn (inline) and peeled onto
/// the canvas (panel).
internal struct PanelDescriptor: Identifiable {
    internal let kind: PanelKind
    internal let title: String
    internal let icon: String
    /// `true` for panels that must not be duplicated. The flamechart is a
    /// singleton because it owns the only 30 Hz redraw timer — one instance
    /// keeps the canvas at today's one-timer cost (the anti-beachball rule).
    internal let singleton: Bool
    /// Builds the panel's content (everything below the title bar) from a
    /// `PanelContext`. `nil` for **host-rendered** panels (e.g. the live
    /// conversation) whose content needs material the context doesn't carry —
    /// the host supplies those views directly and the registry only tracks their
    /// title/icon/singleton metadata.
    internal let build: ((PanelContext) -> AnyView)?
    /// The lens's compact inline form for the per-turn rail. `nil` for
    /// panel-only lenses (thinking/tools/files today) — those are added from the
    /// palette or peeled, and never clutter the rail. A lens with an `inline`
    /// form appears under every turn until it's peeled onto the canvas.
    internal let inline: InlineLens?

    internal var id: String { kind.rawValue }

    /// `true` when the host renders this panel's content itself rather than the
    /// registry building it from a `PanelContext`.
    internal var isHostRendered: Bool { build == nil }

    internal init(
        kind: PanelKind,
        title: String,
        icon: String,
        singleton: Bool = false,
        inline: InlineLens? = nil,
        build: ((PanelContext) -> AnyView)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.icon = icon
        self.singleton = singleton
        self.inline = inline
        self.build = build
    }
}

/// The catalog of panel types the dashboard can show. Built-ins are registered
/// at init; a custom sub-view plugs in with a single `register(_:)` call — its
/// kind then appears in the add-panel palette and its layout persists like any
/// other. The registry is a plain reference type (not a global singleton) so a
/// host can compose its own catalog; `PanelRegistry.standard` is the default.
@MainActor
internal final class PanelRegistry {
    internal private(set) var descriptors: [PanelDescriptor]
    private var byKind: [PanelKind: PanelDescriptor]

    internal init(_ descriptors: [PanelDescriptor] = []) {
        self.descriptors = descriptors
        self.byKind = Dictionary(descriptors.map { ($0.kind, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Register (or replace) a panel kind. This is the extension point: a custom
    /// sub-view calls this once and it becomes a first-class panel.
    internal func register(_ descriptor: PanelDescriptor) {
        if let idx = descriptors.firstIndex(where: { $0.kind == descriptor.kind }) {
            descriptors[idx] = descriptor
        } else {
            descriptors.append(descriptor)
        }
        byKind[descriptor.kind] = descriptor
    }

    internal func descriptor(for kind: PanelKind) -> PanelDescriptor? {
        byKind[kind]
    }

    internal func title(for kind: PanelKind) -> String {
        byKind[kind]?.title ?? kind.rawValue.capitalized
    }

    internal func icon(for kind: PanelKind) -> String {
        byKind[kind]?.icon ?? "questionmark.square.dashed"
    }

    /// Build a panel's content, or a graceful placeholder when its kind isn't
    /// registered (an old saved layout referencing a since-removed custom kind)
    /// or is host-rendered (the host owns its view and should have supplied it
    /// directly — reaching here means it didn't).
    internal func content(for kind: PanelKind, context: PanelContext) -> AnyView {
        guard let build = byKind[kind]?.build else {
            let known = byKind[kind] != nil
            return AnyView(PanelEmptyState(
                icon: "questionmark.square.dashed",
                message: known ? "“\(kind.rawValue)” is rendered by the host" : "Unknown panel “\(kind.rawValue)”"
            ))
        }
        return build(context)
    }

    /// Kinds a user may still add, given what's already on the canvas: everything
    /// except singleton kinds that are already present.
    internal func addableDescriptors(present: [PanelKind]) -> [PanelDescriptor] {
        let presentSet = Set(present)
        return descriptors.filter { !($0.singleton && presentSet.contains($0.kind)) }
    }

    /// The lenses that render in the per-turn inline rail, minus any whose kind
    /// is already a panel on the canvas — a peeled lens leaves the rail so it's
    /// never shown twice. Registration order is preserved, so the rail's lenses
    /// keep a stable left-to-right order across turns.
    internal func inlineLenses(peeled: [PanelKind]) -> [(kind: PanelKind, lens: InlineLens)] {
        let peeledSet = Set(peeled)
        return descriptors.compactMap { descriptor in
            guard let inline = descriptor.inline, !peeledSet.contains(descriptor.kind) else { return nil }
            return (descriptor.kind, inline)
        }
    }

    // MARK: - The standard catalog (built-in lenses)

    internal static let standard: PanelRegistry = {
        let registry = PanelRegistry()
        registry.register(PanelDescriptor(
            kind: .flamechart,
            title: "Flamechart",
            icon: "chart.bar.xaxis",
            singleton: true,
            // Inline: the compact fit-to-width strip (the live timeline the chat
            // has always shown), now rendered under EVERY turn — live or settled
            // — from that turn's nodes. Nil for an empty turn so the rail omits it.
            inline: InlineLens(slot: .wide) { ctx in
                ctx.nodes.isEmpty ? nil : AnyView(
                    InlineTurnTimelineStrip(
                        nodes: ctx.nodes,
                        compactions: ctx.compactions,
                        isStreaming: ctx.isStreaming
                    )
                )
            }
        ) { ctx in
            AnyView(
                ThoughtGraphView(
                    engine: ctx.engine,
                    nodes: ctx.nodes,
                    compactions: ctx.compactions,
                    isStreaming: ctx.isStreaming,
                    isThinking: ctx.isThinking,
                    usageSummary: nil,
                    selection: ctx.selection,
                    onJumpToTool: ctx.onJumpToTool
                )
            )
        })
        registry.register(PanelDescriptor(
            kind: .thinking,
            title: "Thinking",
            icon: "brain"
        ) { ctx in
            AnyView(ThinkingBeatsPanel(nodes: ctx.nodes, isThinking: ctx.isThinking))
        })
        registry.register(PanelDescriptor(
            kind: .runningTools,
            title: "Tools",
            icon: "wrench.and.screwdriver"
        ) { ctx in
            AnyView(RunningToolsPanel(nodes: ctx.nodes, selection: ctx.selection))
        })
        registry.register(PanelDescriptor(
            kind: .skills,
            title: "Skills",
            icon: "sparkles",
            // Inline: the skills chips in the rail's trailing column (the fixed-
            // width lens the streaming turn always pinned right). Nil when the
            // turn recorded no skills — past turns don't persist them yet, so an
            // empty list means "not recorded" and the rail just omits the column.
            inline: InlineLens(slot: .side) { ctx in
                ctx.skills.isEmpty ? nil : AnyView(TurnSkillsLens(skills: ctx.skills))
            }
        ) { ctx in
            AnyView(SkillsPanel(skills: ctx.skills))
        })
        registry.register(PanelDescriptor(
            kind: .files,
            title: "Files",
            icon: "folder"
        ) { ctx in
            AnyView(FilesPanelAdapter(nodes: ctx.nodes, selection: ctx.selection))
        })
        return registry
    }()

    /// The catalog for the **live chat canvas** (Canvas mode in ChatView): the
    /// conversation panel plus the live lenses. The conversation is a
    /// host-rendered singleton — its content is the real chat transcript, which
    /// the host supplies directly (it needs the view model, skin, and scroll
    /// wiring the `PanelContext` deliberately doesn't carry). Listed first so it
    /// leads the add-panel palette.
    internal static let chatCanvas: PanelRegistry = {
        let registry = PanelRegistry()
        registry.register(PanelDescriptor(
            kind: .conversation,
            title: "Conversation",
            icon: "bubble.left.and.bubble.right",
            singleton: true,
            build: nil  // host-rendered — see SessionChatCanvas
        ))
        // Reuse the standard lens builders verbatim.
        for kind in [PanelKind.flamechart, .thinking, .runningTools, .skills, .files] {
            if let descriptor = standard.descriptor(for: kind) {
                registry.register(descriptor)
            }
        }
        // Artifacts — session-global, host-rendered (reads ArtifactStore.shared,
        // not a per-turn context) so it persists across scroll and turn paging.
        registry.register(PanelDescriptor(
            kind: .artifacts,
            title: "Artifacts",
            icon: "shippingbox",
            singleton: true,
            build: nil  // host-rendered — see SessionChatCanvas
        ))
        // Session Graph — the macro all-turns plot, session-global and
        // host-rendered (needs both integrators + jump-to-tool). Docked as a
        // canvas tile instead of a fullscreen sheet.
        registry.register(PanelDescriptor(
            kind: .sessionGraph,
            title: "Session Graph",
            icon: "chart.bar.xaxis",
            singleton: true,
            build: nil  // host-rendered — see SessionChatCanvas
        ))
        return registry
    }()
}

// MARK: - Small adapters for the panels that need a binding shim

/// Wraps `TurnSkillsLens` with an honest empty state — past turns don't persist
/// skills yet, so an empty list means "not recorded", not "no skills".
private struct SkillsPanel: View {
    internal let skills: [SkillInfo]

    internal var body: some View {
        if skills.isEmpty {
            PanelEmptyState(icon: "sparkles", message: "No skills recorded this turn")
        } else {
            ScrollView { TurnSkillsLens(skills: skills).padding(8) }
        }
    }
}

/// Adapts `SessionFileTreePane` (which needs a non-optional `Binding`) to the
/// dashboard's optional shared selection, defaulting to a throwaway binding when
/// the host isn't coordinating cross-highlight.
private struct FilesPanelAdapter: View {
    internal let nodes: [ThoughtGraphNode]
    internal let selection: Binding<String?>?
    @State private var localSelection: String?

    internal var body: some View {
        SessionFileTreePane(nodes: nodes, selectedNodeID: selection ?? $localSelection)
    }
}
