import CoreGraphics
import Foundation
import os

private let layoutLog = Logger(subsystem: "com.researchoors.HermesNative", category: "DashboardLayout")

/// The user's arrangement of panels on the thought-graph dashboard canvas.
/// Persisted as one personal layout (not per-session yet) so the composition a
/// user builds is the composition they get back next time they open the graph.
/// Ordered back-to-front: `panels.last` draws on top and is the focused panel.
internal struct DashboardLayout: Codable, Equatable {
    internal var panels: [DashboardPanel]

    internal init(panels: [DashboardPanel] = []) {
        self.panels = panels
    }

    internal var isEmpty: Bool { panels.isEmpty }

    // MARK: Mutation (front-to-back ordering via array position)

    /// Bring a panel to the front (end of array) so it draws over its
    /// neighbors and receives the next drag. No-op if already frontmost or absent.
    internal mutating func bringToFront(_ id: UUID) {
        guard let idx = panels.firstIndex(where: { $0.id == id }), idx != panels.count - 1 else { return }
        let panel = panels.remove(at: idx)
        panels.append(panel)
    }

    internal mutating func remove(_ id: UUID) {
        panels.removeAll { $0.id == id }
    }

    /// Remove all panels of a given kind (e.g. when docking a lens inside the
    /// conversation panel — the canvas tile is removed and replaced by the dock).
    internal mutating func remove(_ kind: PanelKind) {
        panels.removeAll { $0.kind == kind }
    }

    /// Replace a panel's frame in place (after a drag or resize), preserving order.
    internal mutating func setFrame(_ frame: CGRect, for id: UUID) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].frame = frame
    }

    /// Clamp every panel into the given canvas bounds (window resized, or a
    /// layout saved on a bigger screen is being restored on a smaller one).
    internal func clamped(to bounds: CGSize) -> DashboardLayout {
        guard bounds.width > 0, bounds.height > 0 else { return self }
        return DashboardLayout(panels: panels.map { $0.clamped(to: bounds) })
    }

    /// Scale every panel's frame proportionally when the canvas changes size, so
    /// a layout that filled the old bounds still fills the new ones (going
    /// fullscreen grows the panels instead of leaving dead space; shrinking packs
    /// them back). Origins and sizes scale by the per-axis ratio, then clamp.
    /// No-op when either size is degenerate or unchanged.
    internal func reflowed(from old: CGSize, to new: CGSize) -> DashboardLayout {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else {
            return clamped(to: new)
        }
        guard old != new else { return self }
        let sx = new.width / old.width
        let sy = new.height / old.height
        let scaled = panels.map { panel -> DashboardPanel in
            let f = panel.frame
            let reframed = CGRect(
                x: f.minX * sx, y: f.minY * sy,
                width: f.width * sx, height: f.height * sy
            )
            return DashboardPanel(id: panel.id, kind: panel.kind, frame: reframed)
        }
        return DashboardLayout(panels: scaled).clamped(to: new)
    }

    // MARK: Persistence

    /// The session-graph dashboard's layout (past-turn lenses). v2: v1 layouts
    /// could be saved with overlapping panels by the pre-fix drag bug (every drag
    /// was silently a bottom-right resize); bumping the key discards those so the
    /// clean tiling re-seeds.
    internal static let dashboardKey = "thoughtDashboardLayout.v2"
    /// The live chat canvas's layout (conversation panel + live lenses). Kept
    /// separate so arranging one surface never disturbs the other. v2 for the
    /// same reason as `dashboardKey` — drop stale overlapping arrangements.
    internal static let chatCanvasKey = "sessionChatCanvasLayout.v2"

    /// Load the saved layout for `key`, or `nil` if the user has never arranged
    /// one (the caller then seeds a sensible default). Corrupt JSON is logged and
    /// treated as absent rather than throwing — a broken layout should never
    /// block the surface; the caller just re-seeds the default.
    internal static func loadStored(key: String = dashboardKey) -> DashboardLayout? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let layout = try JSONDecoder().decode(DashboardLayout.self, from: data)
            return layout.isEmpty ? nil : layout
        } catch {
            layoutLog.error("dashboard layout load failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Persist this layout under `key`. Logs and no-ops on an encode failure —
    /// losing a layout is preferable to a crash.
    internal func store(key: String = Self.dashboardKey) {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            layoutLog.error("dashboard layout store failed: \(error.localizedDescription)")
        }
    }

    /// A first-run tiled arrangement, laid out for the given canvas size. Mirrors
    /// today's fixed panes (flamechart dominant, files + skills stacked to its
    /// right) so opening the dashboard the first time looks familiar, then the
    /// user rearranges from there.
    internal static func seededDefault(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width * 2 + 24)
        let h = max(bounds.height, DashboardPanel.minSize.height * 2 + 24)
        let gap: CGFloat = 8
        let rightColumnWidth = max(DashboardPanel.minSize.width, w * 0.28)
        let leftWidth = w - rightColumnWidth - gap * 3
        let rightX = leftWidth + gap * 2
        let halfH = (h - gap * 3) / 2
        return DashboardLayout(panels: [
            DashboardPanel(
                kind: .flamechart,
                frame: CGRect(x: gap, y: gap, width: leftWidth, height: h - gap * 2)
            ),
            DashboardPanel(
                kind: .files,
                frame: CGRect(x: rightX, y: gap, width: rightColumnWidth, height: halfH)
            ),
            DashboardPanel(
                kind: .skills,
                frame: CGRect(x: rightX, y: gap * 2 + halfH, width: rightColumnWidth, height: halfH)
            )
        ]).clamped(to: bounds)
    }

    /// First-run arrangement for the live **chat canvas**: the conversation
    /// dominates the left, with the live flamechart and tools stacked in a right
    /// column. Mirrors how the chat reads today (transcript primary, activity
    /// alongside) so flipping into Canvas mode looks familiar, then the user
    /// rearranges — including dragging the conversation itself.
    /// The default canvas: ONE full-bleed conversation panel. This is the
    /// classic chat expressed as a canvas — the conversation alone, filling the
    /// space. The live lenses (flamechart, tools, thinking, skills, files) and
    /// artifacts are added by the user or peeled out; while the conversation is
    /// the only panel it runs in solo mode and shows the inline live strip, so a
    /// bare canvas reads exactly like today's transcript.
    internal static func seededChatCanvas(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width)
        let h = max(bounds.height, DashboardPanel.minSize.height)
        let gap: CGFloat = 8
        return DashboardLayout(panels: [
            DashboardPanel(
                kind: .conversation,
                frame: CGRect(x: gap, y: gap, width: w - gap * 2, height: h - gap * 2)
            )
        ]).clamped(to: bounds)
    }
}
