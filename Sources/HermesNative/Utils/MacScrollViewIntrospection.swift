#if os(macOS)
import AppKit
import SwiftUI

/// Best-effort AppKit scroll-view cleanup for SwiftUI views whose backing
/// NSScrollView can expose a tiny horizontal scroller/ruler accessory.
struct MacScrollViewIntrospection: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { hideHorizontalScrollers(near: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { hideHorizontalScrollers(near: nsView) }
    }

    private func hideHorizontalScrollers(near view: NSView) {
        guard let root = view.window?.contentView ?? view.superview else { return }
        visit(root)
    }

    private func visit(_ node: NSView) {
        if let scrollView = node as? NSScrollView {
            scrollView.hasHorizontalScroller = false
            scrollView.horizontalScroller = nil
            scrollView.autohidesScrollers = true
            scrollView.hasHorizontalRuler = false
            scrollView.rulersVisible = false

            if let textView = scrollView.documentView as? NSTextView {
                textView.usesRuler = false
                textView.isRulerVisible = false
                textView.usesFindBar = false
                textView.isHorizontallyResizable = false
                textView.textContainer?.widthTracksTextView = true
            }
        }

        for subview in node.subviews {
            visit(subview)
        }
    }
}
#endif
