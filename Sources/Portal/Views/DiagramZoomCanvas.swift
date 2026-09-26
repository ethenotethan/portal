import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Where a rendered diagram is being shown, which decides how zoom behaves.
internal enum DiagramPresentation {
    /// A transcript row. Height follows width, and zoom scales the image inside
    /// the row so the surrounding conversation never reflows.
    case inline
    /// The expanded sheet. The canvas fills the sheet, zoom grows the diagram
    /// past the viewport, and the viewport scrolls and pans over it.
    case expanded
}

/// Pure zoom arithmetic shared by the AppKit and UIKit canvases, kept
/// separate so it is unit-testable without a window.
internal enum DiagramZoomMath {
    /// Zoom bounds relative to the fit-to-viewport scale.
    internal static let minRelative: CGFloat = 0.25
    internal static let maxRelative: CGFloat = 8
    /// One click of the +/− buttons.
    internal static let stepFactor: CGFloat = 1.25

    /// Magnification (1 = one image point per view point) at which `image`
    /// fits entirely inside `viewport`. Degenerate sizes fit at 1.
    internal static func fitScale(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / image.width, viewport.height / image.height)
    }

    internal static func clamp(_ magnification: CGFloat, fit: CGFloat) -> CGFloat {
        min(max(magnification, fit * minRelative), fit * maxRelative)
    }

    /// Displayed percentage, where 100% is fit-to-viewport.
    internal static func percent(_ magnification: CGFloat, fit: CGFloat) -> Int {
        guard fit > 0 else { return 100 }
        return Int((magnification / fit * 100).rounded())
    }

    /// Inset that centers content smaller than the viewport on each axis.
    internal static func centeringInset(content: CGSize, viewport: CGSize) -> (x: CGFloat, y: CGFloat) {
        (max(0, (viewport.width - content.width) / 2), max(0, (viewport.height - content.height) / 2))
    }
}

/// Bridge between the SwiftUI zoom controls and the native scroll view: the
/// canvas publishes the current percentage and installs the action closures.
@MainActor
internal final class DiagramZoomController: ObservableObject {
    @Published internal var percent: Int = 100
    internal var zoomIn: () -> Void = {}
    internal var zoomOut: () -> Void = {}
    internal var fit: () -> Void = {}
}

/// The expanded-sheet diagram: a native zoomable, pannable canvas with a small
/// zoom control cluster. Fills whatever bounded frame it is given.
internal struct ExpandedZoomableDiagram: View {
    internal let image: PlatformImage
    @StateObject private var controller = DiagramZoomController()

    internal var body: some View {
        DiagramZoomCanvas(image: image, controller: controller)
            .overlay(alignment: .bottomTrailing) { controls }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            zoomButton(systemName: "minus", label: "Zoom out", action: controller.zoomOut)
            Text("\(controller.percent)%")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.tertiary)
                .frame(minWidth: 40)
            zoomButton(systemName: "plus", label: "Zoom in", action: controller.zoomIn)
            Divider().frame(height: 12).padding(.horizontal, 4)
            Button(action: controller.fit) {
                Text("Fit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fit diagram to window")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surface.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 0.5))
        .padding(10)
    }

    private func zoomButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#if os(macOS)

/// Clip view that keeps a document smaller than the viewport centered instead
/// of pinned to the bottom-left. Works in document coordinates, so it holds
/// under NSScrollView magnification.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let doc = document.frame
        if doc.width < rect.width { rect.origin.x = doc.minX - (rect.width - doc.width) / 2 }
        if doc.height < rect.height { rect.origin.y = doc.minY - (rect.height - doc.height) / 2 }
        return rect
    }
}

/// Scroll view that zooms on ⌘ + scroll wheel (pinch already zooms natively).
private final class DiagramScrollView: NSScrollView {
    var onCommandScroll: ((CGFloat, NSPoint) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCommandScroll, let documentView else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
        onCommandScroll(delta, documentView.convert(event.locationInWindow, from: nil))
    }
}

internal struct DiagramZoomCanvas: NSViewRepresentable {
    internal let image: PlatformImage
    internal let controller: DiagramZoomController

    internal func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    internal func makeNSView(context: Context) -> NSScrollView {
        let scrollView = DiagramScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.usesPredominantAxisScrolling = false
        scrollView.allowsMagnification = true

        let clipView = CenteringClipView()
        clipView.drawsBackground = false
        clipView.postsBoundsChangedNotifications = true
        scrollView.contentView = clipView

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.frame = NSRect(origin: .zero, size: image.size)
        scrollView.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)

        scrollView.postsFrameChangedNotifications = true
        context.coordinator.attach(scrollView: scrollView, imageSize: image.size)
        scrollView.onCommandScroll = { [weak coordinator = context.coordinator] delta, point in
            coordinator?.zoom(by: exp(delta * 0.01), at: point)
        }
        return scrollView
    }

    internal func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let imageView = nsView.documentView as? NSImageView, imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        context.coordinator.imageSize = image.size
        context.coordinator.refit(force: true)
    }

    @MainActor
    internal final class Coordinator: NSObject {
        private let controller: DiagramZoomController
        private weak var scrollView: NSScrollView?
        fileprivate var imageSize: CGSize = .zero
        private var fitScale: CGFloat = 1
        private var hasLaidOut = false

        internal init(controller: DiagramZoomController) {
            self.controller = controller
        }

        fileprivate func attach(scrollView: NSScrollView, imageSize: CGSize) {
            self.scrollView = scrollView
            self.imageSize = imageSize
            controller.zoomIn = { [weak self] in self?.zoom(by: DiagramZoomMath.stepFactor) }
            controller.zoomOut = { [weak self] in self?.zoom(by: 1 / DiagramZoomMath.stepFactor) }
            controller.fit = { [weak self] in self?.refit(force: true, animated: true) }
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameDidChange), name: NSView.frameDidChangeNotification, object: scrollView
            )
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
        }

        @objc private func frameDidChange(_ note: Notification) {
            refit(force: false)
        }

        @objc private func boundsDidChange(_ note: Notification) {
            publishPercent()
        }

        @objc fileprivate func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            refit(force: true, animated: true)
        }

        /// Recompute the fit scale for the current viewport. Applies it when the
        /// user has not zoomed away from fit (or when forced), so resizing the
        /// sheet keeps a fitted diagram fitted but leaves a zoomed one alone.
        fileprivate func refit(force: Bool, animated: Bool = false) {
            guard let scrollView else { return }
            let viewport = scrollView.contentView.frame.size
            guard viewport.width > 0, viewport.height > 0 else { return }
            let wasAtFit = !hasLaidOut || abs(scrollView.magnification - fitScale) < 0.001
            fitScale = DiagramZoomMath.fitScale(image: imageSize, viewport: viewport)
            scrollView.minMagnification = fitScale * DiagramZoomMath.minRelative
            scrollView.maxMagnification = fitScale * DiagramZoomMath.maxRelative
            if force || wasAtFit {
                let target = NSRect(origin: .zero, size: imageSize)
                if animated {
                    scrollView.animator().magnify(toFit: target)
                } else {
                    scrollView.magnify(toFit: target)
                }
            }
            hasLaidOut = true
            publishPercent()
        }

        fileprivate func zoom(by factor: CGFloat, at point: NSPoint? = nil) {
            guard let scrollView else { return }
            let target = DiagramZoomMath.clamp(scrollView.magnification * factor, fit: fitScale)
            let center = point ?? visibleCenter(of: scrollView)
            scrollView.setMagnification(target, centeredAt: center)
            publishPercent()
        }

        private func visibleCenter(of scrollView: NSScrollView) -> NSPoint {
            let visible = scrollView.contentView.documentVisibleRect
            return NSPoint(x: visible.midX, y: visible.midY)
        }

        private func publishPercent() {
            guard let scrollView else { return }
            let percent = DiagramZoomMath.percent(scrollView.magnification, fit: fitScale)
            guard percent != controller.percent else { return }
            // Bounds notifications can arrive inside a SwiftUI update; defer
            // the published write so it never mutates state mid-render.
            Task { @MainActor [controller] in controller.percent = percent }
        }
    }
}

#else

/// Scroll view that reports layout so the coordinator can refit on rotation
/// and sheet resizes.
private final class DiagramScrollView: UIScrollView {
    var onLayout: ((CGSize) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?(bounds.size)
    }
}

internal struct DiagramZoomCanvas: UIViewRepresentable {
    internal let image: PlatformImage
    internal let controller: DiagramZoomController

    internal func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    internal func makeUIView(context: Context) -> UIScrollView {
        let scrollView = DiagramScrollView()
        scrollView.backgroundColor = .clear
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.bouncesZoom = true
        scrollView.delegate = context.coordinator

        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        scrollView.contentSize = image.size

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        imageView.addGestureRecognizer(doubleTap)

        context.coordinator.attach(scrollView: scrollView, imageView: imageView)
        scrollView.onLayout = { [weak coordinator = context.coordinator] size in
            coordinator?.viewportDidChange(size)
        }
        return scrollView
    }

    internal func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.replaceImage(image)
    }

    @MainActor
    internal final class Coordinator: NSObject, UIScrollViewDelegate {
        private let controller: DiagramZoomController
        private weak var scrollView: UIScrollView?
        private weak var imageView: UIImageView?
        private var fitScale: CGFloat = 1
        private var lastViewport: CGSize = .zero

        internal init(controller: DiagramZoomController) {
            self.controller = controller
        }

        fileprivate func attach(scrollView: UIScrollView, imageView: UIImageView) {
            self.scrollView = scrollView
            self.imageView = imageView
            controller.zoomIn = { [weak self] in self?.zoom(by: DiagramZoomMath.stepFactor) }
            controller.zoomOut = { [weak self] in self?.zoom(by: 1 / DiagramZoomMath.stepFactor) }
            controller.fit = { [weak self] in self?.refit(animated: true) }
        }

        fileprivate func replaceImage(_ image: UIImage) {
            guard let scrollView, let imageView, imageView.image !== image else { return }
            imageView.image = image
            scrollView.zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: image.size)
            scrollView.contentSize = image.size
            lastViewport = .zero
            viewportDidChange(scrollView.bounds.size)
        }

        fileprivate func viewportDidChange(_ viewport: CGSize) {
            guard let scrollView, let imageView, viewport != lastViewport, viewport.width > 0, viewport.height > 0 else { return }
            let first = lastViewport == .zero
            let wasAtFit = first || abs(scrollView.zoomScale - fitScale) < 0.001
            lastViewport = viewport
            let imageSize = imageView.image?.size ?? .zero
            fitScale = DiagramZoomMath.fitScale(image: imageSize, viewport: viewport)
            scrollView.minimumZoomScale = fitScale * DiagramZoomMath.minRelative
            scrollView.maximumZoomScale = fitScale * DiagramZoomMath.maxRelative
            if wasAtFit { scrollView.zoomScale = fitScale }
            center()
            publishPercent()
        }

        internal func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        internal func scrollViewDidZoom(_ scrollView: UIScrollView) {
            center()
            publishPercent()
        }

        @objc fileprivate func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            refit(animated: true)
        }

        private func refit(animated: Bool) {
            scrollView?.setZoomScale(fitScale, animated: animated)
        }

        private func zoom(by factor: CGFloat) {
            guard let scrollView else { return }
            scrollView.setZoomScale(DiagramZoomMath.clamp(scrollView.zoomScale * factor, fit: fitScale), animated: true)
        }

        /// Keep a diagram smaller than the viewport centered on both axes.
        private func center() {
            guard let scrollView, let imageView else { return }
            let inset = DiagramZoomMath.centeringInset(content: imageView.frame.size, viewport: scrollView.bounds.size)
            scrollView.contentInset = UIEdgeInsets(top: inset.y, left: inset.x, bottom: inset.y, right: inset.x)
        }

        private func publishPercent() {
            guard let scrollView else { return }
            let percent = DiagramZoomMath.percent(scrollView.zoomScale, fit: fitScale)
            guard percent != controller.percent else { return }
            Task { @MainActor [controller] in controller.percent = percent }
        }
    }
}

#endif
