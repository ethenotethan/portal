import Testing
@testable import HermesNative

/// The inline-lens contract that drives the per-turn rail ↔ canvas peel: which
/// lenses render inline, in what order, and how peeling one (adding its panel to
/// the canvas) removes it from the rail. This is the pure core of the
/// "one definition, two placements" unification — kept honest here so a future
/// lens registration can't silently break rail/peel behaviour.
@MainActor
@Suite("Panel registry inline lenses")
internal struct PanelRegistryInlineTests {
    @Test("The chat canvas exposes the flamechart and skills as inline lenses")
    internal func chatCanvasHasInlineLenses() {
        let kinds = PanelRegistry.chatCanvas.inlineLenses(peeled: []).map(\.kind)
        #expect(kinds.contains(.flamechart))
        #expect(kinds.contains(.skills))
    }

    @Test("Panel-only lenses never appear in the inline rail")
    internal func panelOnlyLensesStayOffTheRail() {
        let kinds = PanelRegistry.chatCanvas.inlineLenses(peeled: []).map(\.kind)
        // Thinking, tools, and files are canvas panels only — they must not
        // clutter the per-turn rail.
        #expect(!kinds.contains(.thinking))
        #expect(!kinds.contains(.runningTools))
        #expect(!kinds.contains(.files))
        // Nor do host-rendered globals leak into the rail.
        #expect(!kinds.contains(.conversation))
        #expect(!kinds.contains(.sessionGraph))
    }

    @Test("Peeling a lens removes exactly it from the rail, keeping the rest")
    internal func peelingRemovesOnlyThatLens() {
        let registry = PanelRegistry.chatCanvas
        let before = registry.inlineLenses(peeled: []).map(\.kind)
        let after = registry.inlineLenses(peeled: [.flamechart]).map(\.kind)

        #expect(!after.contains(.flamechart))          // the peeled lens left the rail
        #expect(after.contains(.skills) == before.contains(.skills))  // others untouched
        #expect(after.count == before.count - 1)
    }

    @Test("Peeling every inline lens empties the rail")
    internal func peelingAllEmptiesRail() {
        let registry = PanelRegistry.chatCanvas
        let all = registry.inlineLenses(peeled: []).map(\.kind)
        #expect(registry.inlineLenses(peeled: all).isEmpty)
    }

    @Test("Inline lens order is stable — matches registration order both times")
    internal func inlineOrderIsStable() {
        let registry = PanelRegistry.chatCanvas
        let first = registry.inlineLenses(peeled: []).map(\.kind)
        let second = registry.inlineLenses(peeled: []).map(\.kind)
        #expect(first == second)
        // Flamechart is registered before skills, so it leads the rail.
        if let fIdx = first.firstIndex(of: .flamechart), let sIdx = first.firstIndex(of: .skills) {
            #expect(fIdx < sIdx)
        } else {
            Issue.record("Expected both flamechart and skills inline lenses")
        }
    }

    @Test("The flamechart inline lens is wide; skills is a side column")
    internal func inlineSlotsMatchTheStreamingLayout() {
        let lenses = PanelRegistry.chatCanvas.inlineLenses(peeled: [])
        let flame = lenses.first { $0.kind == .flamechart }
        let skills = lenses.first { $0.kind == .skills }
        #expect(flame?.lens.slot == .wide)
        #expect(skills?.lens.slot == .side)
    }
}
