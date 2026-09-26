import CoreGraphics
import Testing
@testable import Portal

/// The expanded diagram sheet zooms through a native scroll view; this is the
/// arithmetic both platform canvases share, pinned without needing a window.
@Suite("Diagram zoom math")
internal struct DiagramZoomMathTests {

    @Test("Fit scale is bounded by the tighter axis")
    internal func fitScaleUsesTighterAxis() {
        // Wide image in a squarer viewport: width binds.
        #expect(DiagramZoomMath.fitScale(image: CGSize(width: 2000, height: 500), viewport: CGSize(width: 1000, height: 800)) == 0.5)
        // Tall image: height binds.
        #expect(DiagramZoomMath.fitScale(image: CGSize(width: 400, height: 1600), viewport: CGSize(width: 1000, height: 800)) == 0.5)
        // Small image is scaled UP to fill, so a tiny diagram is not a postage stamp.
        #expect(DiagramZoomMath.fitScale(image: CGSize(width: 100, height: 50), viewport: CGSize(width: 1000, height: 800)) == 10)
    }

    @Test("Degenerate sizes fit at 1 instead of dividing by zero")
    internal func degenerateSizesFitAtOne() {
        #expect(DiagramZoomMath.fitScale(image: .zero, viewport: CGSize(width: 100, height: 100)) == 1)
        #expect(DiagramZoomMath.fitScale(image: CGSize(width: 100, height: 100), viewport: .zero) == 1)
    }

    @Test("Clamp keeps magnification within the relative bounds of fit")
    internal func clampBoundsRelativeToFit() {
        let fit: CGFloat = 0.5
        #expect(DiagramZoomMath.clamp(0.01, fit: fit) == fit * DiagramZoomMath.minRelative)
        #expect(DiagramZoomMath.clamp(100, fit: fit) == fit * DiagramZoomMath.maxRelative)
        #expect(DiagramZoomMath.clamp(1.0, fit: fit) == 1.0)
    }

    @Test("Percent is relative to fit and rounds")
    internal func percentRelativeToFit() {
        #expect(DiagramZoomMath.percent(0.5, fit: 0.5) == 100)
        #expect(DiagramZoomMath.percent(1.0, fit: 0.5) == 200)
        #expect(DiagramZoomMath.percent(0.626, fit: 0.5) == 125)
        #expect(DiagramZoomMath.percent(0.5, fit: 0) == 100)
    }

    @Test("Centering inset is half the slack, never negative")
    internal func centeringInset() {
        let inset = DiagramZoomMath.centeringInset(content: CGSize(width: 400, height: 300), viewport: CGSize(width: 1000, height: 200))
        #expect(inset.x == 300)
        #expect(inset.y == 0)
    }
}
