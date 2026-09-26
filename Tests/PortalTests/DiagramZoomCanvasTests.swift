#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import Portal

/// Hosts the expanded-sheet canvas in an offscreen window and checks the
/// behaviour the SwiftUI `scaleEffect` path could not deliver: zoom past fit
/// makes the document larger than the viewport, so it scrolls instead of
/// clipping, and the controls round-trip through the controller.
@Suite("Diagram zoom canvas", .serialized)
@MainActor
internal struct DiagramZoomCanvasTests {

    private static let imageSize = CGSize(width: 2000, height: 500)
    private static let viewport = CGSize(width: 1000, height: 800)

    private static func host() throws -> (NSWindow, NSScrollView, DiagramZoomController) {
        let image = NSImage(size: imageSize, flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let controller = DiagramZoomController()
        let hosting = NSHostingView(rootView: DiagramZoomCanvas(image: image, controller: controller))
        hosting.frame = NSRect(origin: .zero, size: viewport)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let scrollView = try #require(firstScrollView(in: hosting))
        return (window, scrollView, controller)
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    /// Let frame notifications and the controller's deferred percent write land.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test("Opens fitted to the viewport")
    internal func opensAtFit() async throws {
        let (window, scrollView, controller) = try Self.host()
        defer { window.orderOut(nil) }
        await Self.settle()
        let fit = DiagramZoomMath.fitScale(image: Self.imageSize, viewport: scrollView.contentView.frame.size)
        #expect(abs(scrollView.magnification - fit) < 0.001)
        #expect(controller.percent == 100)
        // Whole document visible: nothing to scroll.
        #expect(scrollView.contentView.documentVisibleRect.width >= Self.imageSize.width - 1)
    }

    @Test("Zooming in grows the document past the viewport instead of clipping")
    internal func zoomInMakesDocumentScrollable() async throws {
        let (window, scrollView, controller) = try Self.host()
        defer { window.orderOut(nil) }
        await Self.settle()
        let before = scrollView.magnification
        controller.zoomIn()
        controller.zoomIn()
        await Self.settle()
        #expect(abs(scrollView.magnification - before * DiagramZoomMath.stepFactor * DiagramZoomMath.stepFactor) < 0.001)
        // The visible slice of the document is now smaller than the document,
        // which is exactly "you can pan to the rest of it".
        #expect(scrollView.contentView.documentVisibleRect.width < Self.imageSize.width - 1)
        #expect(controller.percent == 156)
    }

    @Test("Zoom is clamped to the relative bounds of fit")
    internal func zoomClamps() async throws {
        let (window, scrollView, controller) = try Self.host()
        defer { window.orderOut(nil) }
        await Self.settle()
        let fit = scrollView.magnification
        for _ in 0..<40 { controller.zoomIn() }
        #expect(abs(scrollView.magnification - fit * DiagramZoomMath.maxRelative) < 0.001)
        for _ in 0..<60 { controller.zoomOut() }
        #expect(abs(scrollView.magnification - fit * DiagramZoomMath.minRelative) < 0.001)
    }
}
#endif
