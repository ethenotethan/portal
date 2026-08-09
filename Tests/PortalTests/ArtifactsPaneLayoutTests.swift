import Testing
@testable import Portal

@Suite("Artifacts pane layout")
@MainActor
internal struct ArtifactsPaneLayoutTests {
    @Test("Compact widths use drill-down navigation instead of a side-by-side split")
    internal func compactWidthUsesDrillDown() {
        #expect(ArtifactsPane.layoutMode(isCompactWidth: true) == .drillDown)
    }

    @Test("Regular widths retain the artifact list and detail split")
    internal func regularWidthUsesSplit() {
        #expect(ArtifactsPane.layoutMode(isCompactWidth: false) == .split)
    }
}
