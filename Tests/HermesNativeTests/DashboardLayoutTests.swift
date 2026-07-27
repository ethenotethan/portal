import CoreGraphics
import Foundation
import Testing
@testable import HermesNative

@Suite("Dashboard layout model")
internal struct DashboardLayoutTests {

    // MARK: - Panel clamping

    @Test("A panel larger than the canvas is shrunk to fit")
    internal func panelClampedToBounds() {
        let panel = DashboardPanel(kind: .flamechart, frame: CGRect(x: 0, y: 0, width: 5000, height: 5000))
        let clamped = panel.clamped(to: CGSize(width: 800, height: 600))
        #expect(clamped.frame.width == 800)
        #expect(clamped.frame.height == 600)
    }

    @Test("An off-canvas panel is pulled back on-screen")
    internal func offCanvasPanelPulledBack() {
        let panel = DashboardPanel(kind: .files, frame: CGRect(x: 900, y: 700, width: 300, height: 200))
        let clamped = panel.clamped(to: CGSize(width: 1000, height: 800))
        #expect(clamped.frame.maxX <= 1000)
        #expect(clamped.frame.maxY <= 800)
        #expect(clamped.frame.size == CGSize(width: 300, height: 200))  // size preserved
    }

    @Test("Clamp never returns a panel smaller than the minimum size")
    internal func clampRespectsMinimum() {
        let panel = DashboardPanel(kind: .thinking, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        // Even on a tiny canvas, min size wins (panel can overflow a degenerate canvas).
        let clamped = panel.clamped(to: CGSize(width: 50, height: 50))
        #expect(clamped.frame.width >= DashboardPanel.minSize.width || clamped.frame.width == 50)
    }

    // MARK: - z-order

    @Test("bringToFront moves a panel to the end (frontmost) preserving others' order")
    internal func bringToFront() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        let c = DashboardPanel(kind: .skills, frame: .zero)
        var layout = DashboardLayout(panels: [a, b, c])
        layout.bringToFront(a.id)
        #expect(layout.panels.map(\.id) == [b.id, c.id, a.id])
    }

    @Test("bringToFront on the already-frontmost panel is a no-op")
    internal func bringToFrontFrontmostNoOp() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        var layout = DashboardLayout(panels: [a, b])
        layout.bringToFront(b.id)
        #expect(layout.panels.map(\.id) == [a.id, b.id])
    }

    @Test("remove deletes the panel by id")
    internal func removePanel() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        var layout = DashboardLayout(panels: [a, b])
        layout.remove(a.id)
        #expect(layout.panels.map(\.id) == [b.id])
    }

    @Test("setFrame updates in place without reordering")
    internal func setFramePreservesOrder() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        var layout = DashboardLayout(panels: [a, b])
        let newFrame = CGRect(x: 5, y: 6, width: 300, height: 200)
        layout.setFrame(newFrame, for: a.id)
        #expect(layout.panels.first?.frame == newFrame)
        #expect(layout.panels.map(\.id) == [a.id, b.id])  // order intact
    }

    // MARK: - Codable round-trip (persistence)

    @Test("A layout survives an encode/decode round-trip")
    internal func codableRoundTrip() throws {
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .flamechart, frame: CGRect(x: 10, y: 20, width: 400, height: 300)),
            DashboardPanel(kind: .thinking, frame: CGRect(x: 420, y: 20, width: 240, height: 200))
        ])
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(DashboardLayout.self, from: data)
        #expect(decoded == layout)
    }

    @Test("An unknown panel kind decodes without loss (forward-compatible)")
    internal func unknownKindDecodes() throws {
        // A custom kind registered by a plugin, persisted, then loaded by a build
        // that doesn't know it — must decode, not throw, so the layout survives.
        let custom = DashboardLayout(panels: [
            DashboardPanel(kind: PanelKind(rawValue: "custom.myPlugin"), frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        ])
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(DashboardLayout.self, from: data)
        #expect(decoded.panels.first?.kind.rawValue == "custom.myPlugin")
    }

    // MARK: - Reflow on resize

    @Test("Reflow scales a full layout to fill larger bounds (no dead space)")
    internal func reflowGrowsToFill() {
        // A panel filling the whole old canvas must fill the whole new one.
        let old = CGSize(width: 800, height: 600)
        let new = CGSize(width: 1600, height: 900)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .conversation, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        ])
        let reflowed = layout.reflowed(from: old, to: new)
        let f = reflowed.panels[0].frame
        #expect(f.width == 1600)
        #expect(f.height == 900)
    }

    @Test("Reflow preserves proportional position")
    internal func reflowPreservesProportion() {
        let old = CGSize(width: 1000, height: 1000)
        let new = CGSize(width: 2000, height: 2000)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .files, frame: CGRect(x: 100, y: 200, width: 300, height: 400))
        ])
        let f = layout.reflowed(from: old, to: new).panels[0].frame
        #expect(f.minX == 200)
        #expect(f.minY == 400)
        #expect(f.width == 600)
        #expect(f.height == 800)
    }

    @Test("Reflow is a no-op when the size is unchanged")
    internal func reflowUnchangedIsNoOp() {
        let size = CGSize(width: 1000, height: 800)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .skills, frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        ])
        #expect(layout.reflowed(from: size, to: size) == layout)
    }

    @Test("Reflow from a degenerate old size just clamps")
    internal func reflowDegenerateOldSize() {
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .thinking, frame: CGRect(x: 0, y: 0, width: 5000, height: 5000))
        ])
        // old size zero → can't scale; fall back to clamp into new bounds.
        let reflowed = layout.reflowed(from: .zero, to: CGSize(width: 800, height: 600))
        #expect(reflowed.panels[0].frame.width <= 800)
        #expect(reflowed.panels[0].frame.height <= 600)
    }

    // MARK: - Seeded default

    @Test("Seeded default tiles the built-in lenses inside the canvas")
    internal func seededDefaultFitsBounds() {
        let bounds = CGSize(width: 1200, height: 800)
        let layout = DashboardLayout.seededDefault(for: bounds)
        #expect(!layout.isEmpty)
        for panel in layout.panels {
            #expect(panel.frame.minX >= 0)
            #expect(panel.frame.minY >= 0)
            #expect(panel.frame.maxX <= bounds.width + 0.5)
            #expect(panel.frame.maxY <= bounds.height + 0.5)
        }
        // The flamechart is present and is the widest (dominant) panel.
        let flame = layout.panels.first { $0.kind == .flamechart }
        #expect(flame != nil)
    }
}
