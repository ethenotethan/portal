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

    internal init(id: UUID = UUID(), kind: PanelKind, frame: CGRect) {
        self.id = id
        self.kind = kind
        self.frame = frame
    }

    /// Smallest a panel may be shrunk to — keeps the chrome (title bar + grips)
    /// usable and the content non-degenerate.
    internal static let minSize = CGSize(width: 200, height: 140)

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
        return DashboardPanel(id: id, kind: kind, frame: f)
    }
}
