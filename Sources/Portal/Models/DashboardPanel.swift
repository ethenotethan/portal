import CoreGraphics
import Foundation

/// Identifies WHAT a dashboard panel shows. Deliberately a `RawRepresentable`
/// struct rather than a closed enum: built-in lenses are static constants, but
/// a custom sub-view can register a brand-new kind at runtime (see
/// `PanelRegistry`) without touching this type. A layout that references a kind
/// no one registered still decodes — it just renders the registry's
/// "unknown panel" placeholder, so old saved layouts never crash.
internal struct PanelKind: RawRepresentable, Codable, Hashable, Identifiable {
    internal let rawValue: String
    internal var id: String { rawValue }

    internal init(rawValue: String) {
        self.rawValue = rawValue
    }

    // MARK: Built-in lenses (the existing thought-graph surfaces, made composable)

    /// The time-plot flamechart — tool bars, subagent lanes, reasoning diamonds.
    internal static let flamechart = PanelKind(rawValue: "flamechart")
    /// Reasoning / thinking beats, rendered as a readable list of gists.
    internal static let thinking = PanelKind(rawValue: "thinking")
    /// The live running-tools trace.
    internal static let runningTools = PanelKind(rawValue: "runningTools")
    /// The self-organizing skills taxonomy for the turn ("what").
    internal static let skills = PanelKind(rawValue: "skills")
    /// Files this turn touched ("where").
    internal static let files = PanelKind(rawValue: "files")
    /// The live chat conversation itself — the transcript where the user and
    /// agent exchange turns. A first-class, resizable panel on the session
    /// canvas so the chat docks alongside the lenses instead of owning the whole
    /// screen. Singleton (there is one conversation) and host-rendered: its
    /// content comes from the chat view, not a `PanelContext`, so the registry
    /// never builds it.
    internal static let conversation = PanelKind(rawValue: "conversation")
    /// The session's living artifacts (maps, datasets, docs, HTML pages the
    /// agent maintains). Session-global — it reads `ArtifactStore.shared`, so it
    /// persists regardless of transcript scroll or which turn is selected: an
    /// artifact stays put on the canvas while you page turns or scroll the chat.
    /// Singleton (one artifacts pane) and host-rendered (it needs the store, not
    /// a per-turn `PanelContext`).
    internal static let artifacts = PanelKind(rawValue: "artifacts")
    /// The macro all-turns Session Graph — every turn's flamechart replayed in
    /// one plot. Session-global (it spans the whole conversation, not one turn)
    /// and host-rendered: it needs both graph integrators and a jump-to-tool
    /// callback the per-turn `PanelContext` doesn't carry, so the host builds it.
    /// Opened as an in-canvas tile rather than a fullscreen sheet, so it docks
    /// beside the conversation like any other lens.
    internal static let sessionGraph = PanelKind(rawValue: "sessionGraph")
    /// Delegation batches — the async waves of subagents this session spawned,
    /// each shown as a flamechart of concurrent subagent lanes (start → end,
    /// cost, tokens). Session-global and host-rendered: it reads the session's
    /// `SpawnTreeStore` tree, not the per-turn `PanelContext`, and updates live
    /// as batch members stream in. This is the introspection surface behind the
    /// `[ASYNC DELEGATION BATCH COMPLETE]` marker.
    internal static let delegationBatch = PanelKind(rawValue: "delegationBatch")
    /// The sessions search + filter panel — text search and status/source filter
    /// pills. Drives the shared `SessionsFilterState` which the list and timeline
    /// panels both observe. Host-rendered singleton on the sessions canvas.
    internal static let sessionsSearch = PanelKind(rawValue: "sessionsSearch")
    /// The sessions list panel — the card-based session browser filtered by the
    /// shared `SessionsFilterState`. Host-rendered singleton on the sessions canvas.
    internal static let sessionsList = PanelKind(rawValue: "sessionsList")
    /// A horizontal time plot of all sessions — start → end bars grouped by source
    /// lane. Host-rendered singleton on the sessions canvas.
    internal static let sessionsTimeline = PanelKind(rawValue: "sessionsTimeline")
    /// Aggregate stat tiles — sessions today, avg duration, message count, error
    /// rate. Host-rendered singleton on the sessions canvas.
    internal static let sessionsStats = PanelKind(rawValue: "sessionsStats")
    /// Inline session inspector — shows metadata and run-state detail for the
    /// session selected in the list or timeline. Host-rendered singleton.
    internal static let sessionsDetail = PanelKind(rawValue: "sessionsDetail")
    /// Categorical breakdown of sessions by source — donut chart + legend.
    /// Host-rendered singleton on the sessions canvas.
    internal static let sessionsSourceBreakdown = PanelKind(rawValue: "sessionsSourceBreakdown")

    // MARK: Cron activity canvas lenses (host-rendered singletons)

    /// Total / OK / Errors / Success-rate tiles for the filtered window.
    internal static let cronSummary = PanelKind(rawValue: "cronSummary")
    /// Stacked OK/Error activation-volume-over-time bar chart.
    internal static let cronVolume = PanelKind(rawValue: "cronVolume")
    /// The live jobs list — expandable cards with pause/resume/remove/edit.
    internal static let cronJobs = PanelKind(rawValue: "cronJobs")
    /// Lane-per-job scatter of activations across the window.
    internal static let cronTimeline = PanelKind(rawValue: "cronTimeline")
    /// Per-job OK/Error split bar + success-rate + count rows.
    internal static let cronBreakdown = PanelKind(rawValue: "cronBreakdown")
}

/// One panel on the dashboard canvas: a kind (what it shows) placed at a frame
/// (where and how big). Free-form — the frame is absolute points in the canvas
/// coordinate space, so the user drags and resizes it anywhere. z-order is the
/// panel's position in `DashboardLayout.panels` (last = frontmost), so it needs
/// no stored field of its own.
internal struct DashboardPanel: Codable, Identifiable, Equatable {
    internal let id: UUID
    internal var kind: PanelKind
    internal var frame: CGRect
    /// When `true` the panel shows only its title bar; the content is hidden.
    /// The frame is preserved so expanding snaps the panel back to its previous size.
    internal var isCollapsed: Bool

    internal init(id: UUID = UUID(), kind: PanelKind, frame: CGRect, isCollapsed: Bool = false) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.isCollapsed = isCollapsed
    }

    /// Smallest a panel may be shrunk to — keeps the chrome (title bar + grips)
    /// usable and the content non-degenerate.
    internal static let minSize = CGSize(width: 200, height: 140)
    /// Height of the title bar — the visible height when a panel is collapsed.
    internal static let titleBarHeight: CGFloat = 28

    /// Return this panel with its frame clamped so it stays at least partially
    /// on-canvas and no smaller than `minSize`. Used on load (a saved layout may
    /// have been made on a larger window) and after every drag/resize.
    internal func clamped(to bounds: CGSize) -> DashboardPanel {
        var f = frame
        f.size.width = max(Self.minSize.width, min(f.size.width, bounds.width))
        f.size.height = max(Self.minSize.height, min(f.size.height, bounds.height))
        // Keep the whole frame inside the canvas when it fits; otherwise pin to origin.
        f.origin.x = min(max(0, f.origin.x), max(0, bounds.width - f.size.width))
        f.origin.y = min(max(0, f.origin.y), max(0, bounds.height - f.size.height))
        return DashboardPanel(id: id, kind: kind, frame: f, isCollapsed: isCollapsed)
    }
}
