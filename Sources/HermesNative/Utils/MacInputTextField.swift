#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "MacInputTextField")

// MARK: - MacInputTextField

/// A native NSTextView wrapper that supports multi-line input with dynamic height.
///
/// - Single-line: horizontal scroll (like before)
/// - Multi-line: grows vertically up to `maxLines` (default 8), then scrolls
/// - Return sends, Shift+Return inserts newline
struct MacInputTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isFocused: FocusState<Bool>.Binding
    @Binding var fieldRef: FocusableTextView?
    var onSubmit: () -> Void
    var onImagePaste: ([NSItemProvider]) -> Void
    var onTextChange: ((String) -> Void)?
    var onNavigateUp: (() -> Void)?
    var onNavigateDown: (() -> Void)?
    var onConfirm: (() -> Void)?
    var maxLines: Int = 8

    func makeNSView(context: Context) -> NSScrollView {
        let tv = FocusableTextView()
        tv.placeholder = placeholder
        tv.maxLines = maxLines
        tv.font = .systemFont(ofSize: 15, weight: .regular)
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onImagePaste = onImagePaste
        tv.onHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.applyReportedHeight(height)
        }
        tv.onTextChange = onTextChange
        tv.onNavigateUp = onNavigateUp
        tv.onNavigateDown = onNavigateDown
        tv.onConfirmSelection = onConfirm
        tv.setAccessibilityIdentifier("chatInput")
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.lineFragmentPadding = 2
        // Inside the scroll view the text view must grow vertically with its
        // content; the scroll view shows a scroller once the SwiftUI frame
        // (capped at maxLines) is smaller than the document.
        tv.autoresizingMask = [.width]
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .automatic
        // Overlay scrollers MUST be forced here: with a mouse attached macOS
        // defaults to legacy scrollers, which consume content width. Near the
        // max-line cap that feeds back (scroller shows → text rewraps → height
        // drops → scroller hides → …) into an infinite layout oscillation.
        scroll.scrollerStyle = .overlay

        context.coordinator.textView = tv
        DispatchQueue.main.async {
            fieldRef = tv
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let nsView = scrollView.documentView as? FocusableTextView else { return }
        if nsView.string != text {
            let selectedRanges = nsView.selectedRanges
            nsView.string = text
            if let range = selectedRanges.first as? NSRange,
               range.location <= nsView.string.count {
                nsView.setSelectedRange(range)
            }
            nsView.scrollRangeToVisible(nsView.selectedRange())
            // External text change (e.g. cleared after send, slash-insert) —
            // recompute reported height so the field grows/shrinks to match.
            nsView.reportContentHeight()
        }
        nsView.placeholder = placeholder
        nsView.onSubmit = onSubmit
        nsView.onImagePaste = onImagePaste
        nsView.onHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.applyReportedHeight(height)
        }
        nsView.onTextChange = onTextChange
        nsView.onNavigateUp = onNavigateUp
        nsView.onNavigateDown = onNavigateDown
        nsView.onConfirmSelection = onConfirm
        nsView.maxLines = maxLines

        if fieldRef !== nsView {
            DispatchQueue.main.async {
                fieldRef = nsView
            }
        }

        let nowFocused = isFocused.wrappedValue
        if nowFocused && !context.coordinator.wasFocused {
            makeFirstResponder(nsView)
        }
        context.coordinator.wasFocused = nowFocused
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scrollView: NSScrollView, context: Context) -> CGSize? {
        // DURABLE FIX for the recurring layout-loop beachball.
        //
        // The old design RETURNED a height computed from the proposed width.
        // That is inherently self-referential: SwiftUI proposes a width →
        // we return a height → the parent reflows → proposes a slightly
        // different width → we return a slightly different height → … an
        // infinite relayout that pegs the main thread. Quantization + caches
        // only narrowed the window; under a ScrollView/LazyVStack host (which
        // re-proposes aggressively) it still oscillated.
        //
        // Now: do NOT derive height from the proposal here. Accept SwiftUI's
        // proposed width (return nil width) and report a height that the
        // AppKit side already computed on the last *content* change
        // (coordinator.reportedHeight) — a value that does NOT change when the
        // proposed width jitters. With height no longer a function of the
        // proposed width, the feedback loop cannot form.
        guard let nsView = scrollView.documentView as? FocusableTextView else { return nil }
        let coordinator = context.coordinator
        if let w = proposal.width, w.isFinite, w > 0 { coordinator.lastMeasuredWidth = w }
        let width = proposal.width ?? coordinator.lastMeasuredWidth ?? 300
        // Height comes from the AppKit view's reported content height (updated
        // only on text changes), clamped to maxLines — NOT recomputed from the
        // proposed width. This is what prevents the relayout feedback loop.
        let height = coordinator.clampedReportedHeight(font: nsView.font, maxLines: nsView.maxLines)
        return CGSize(width: width, height: height)
    }

    private func makeFirstResponder(_ nsView: FocusableTextView) {
        let attempt: () -> Void = { [weak nsView] in
            guard let nsView, let window = nsView.window else { return }
            guard window.firstResponder !== nsView else { return }
            nsView.isEditable = true
            window.makeFirstResponder(nil)
            window.makeFirstResponder(nsView)
        }
        DispatchQueue.main.async(execute: attempt)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    /// MainActor by construction — every caller is AppKit layout / text
    /// delegate machinery on the main thread; the isolation makes the
    /// deferred invalidation hop compile under strict concurrency.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency NSTextViewDelegate {
        var parent: MacInputTextField
        weak var textView: FocusableTextView?
        var wasFocused: Bool = false
        var lastMeasuredWidth: CGFloat?
        /// Content height reported by the AppKit text view on its last text
        /// change. This is the single source of truth for the field's height;
        /// sizeThatFits returns it verbatim (clamped), so the height never
        /// varies with the proposed width and the relayout loop can't form.
        var reportedHeight: CGFloat?
        /// Deferred invalidation scheduled for the next runloop turn.
        private var pendingInvalidation = false
        /// Height changes below this are absorbed, not propagated. AppKit
        /// text layout is not width-stable at sub-point scale: relayout of
        /// the SAME text at a jittering width can move usedRect by a
        /// fraction of a point, and each propagated fraction re-enters
        /// SwiftUI layout — which jitters the width again. Half a point is
        /// invisible; a real line change is ~18pt.
        private static let heightTolerance: CGFloat = 0.5

        /// Absorb sub-point height noise and defer the SwiftUI invalidation
        /// out of the current layout pass.
        ///
        /// reportContentHeight fires from didChangeText but ALSO after
        /// AppKit resizes/relayouts the text view — which happens INSIDE
        /// SwiftUI's own layout pass (sizeThatFits → NSScrollView layout →
        /// usedRect shift → onHeightChange → invalidateIntrinsicContentSize
        /// → new layout pass → …). Invalidating synchronously from within
        /// layout is what re-arms the loop the sizeThatFits comment says
        /// can't form; deferring to the next runloop turn coalesces the
        /// storm to one invalidation, and the tolerance stops the fixed
        /// point from oscillating between two sub-point heights.
        ///
        func applyReportedHeight(_ height: CGFloat) {
            let current = reportedHeight
            guard current == nil || abs(current! - height) > Self.heightTolerance else { return }
            reportedHeight = height
            guard !pendingInvalidation else { return }
            pendingInvalidation = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingInvalidation = false
                self.textView?.enclosingScrollView?.invalidateIntrinsicContentSize()
            }
        }

        init(_ parent: MacInputTextField) {
            self.parent = parent
        }

        /// Reported height clamped to [1 line, maxLines]; falls back to a
        /// single line before the first measurement arrives.
        func clampedReportedHeight(font: NSFont?, maxLines: Int) -> CGFloat {
            let f = font ?? .systemFont(ofSize: 15, weight: .regular)
            let lineHeight = f.boundingRectForFont.height
            let minH = lineHeight + 12
            let maxH = lineHeight * CGFloat(maxLines) + 12
            let h = reportedHeight ?? minH
            return min(max(h, minH), maxH)
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }
    }
}

// MARK: - FocusableTextView

/// Multi-line NSTextView with placeholder, height tracking, Return-to-send.
final class FocusableTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onImagePaste: (([NSItemProvider]) -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onNavigateUp: (() -> Void)?
    var onNavigateDown: (() -> Void)?
    var onConfirmSelection: (() -> Void)?
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }
    var maxLines: Int = 8

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let window else { return }
        guard window.firstResponder !== self else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            guard window.firstResponder !== self else { return }
            self.isEditable = true
            window.makeFirstResponder(nil)
            window.makeFirstResponder(self)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            let pb = NSPasteboard.general
            if pb.canReadObject(forClasses: [NSImage.self, NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) {
                var providers: [NSItemProvider] = []

                if let urls = pb.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                    // Accept any pasted file type — documents are extracted or
                    // uploaded downstream, not just images.
                    for url in urls {
                        if let provider = NSItemProvider(contentsOf: url) {
                            providers.append(provider)
                        }
                    }
                }

                for type in [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType.png] {
                    if let data = pb.data(forType: type) {
                        let provider = NSItemProvider()
                        provider.registerDataRepresentation(forTypeIdentifier: UTType.image.identifier,
                                                             visibility: .all) { completion in
                            completion(data, nil)
                            return nil
                        }
                        providers.append(provider)
                        break
                    }
                }

                if !providers.isEmpty {
                    onImagePaste?(providers)
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) == false,
           event.characters == "\r" {
            if onConfirmSelection != nil {
                onConfirmSelection?()
            } else {
                onSubmit?()
            }
            return
        }

        let arrowKey = event.specialKey
        if arrowKey == .upArrow, let nav = onNavigateUp {
            nav()
            return
        }
        if arrowKey == .downArrow, let nav = onNavigateDown {
            nav()
            return
        }

        super.keyDown(with: event)
    }

    // Force plain text on paste — rich pastes (from browsers, PDFs, terminals)
    // otherwise carry foreign fonts/colors even with isRichText = false.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChange?(string)
        scrollRangeToVisible(selectedRange())
        reportContentHeight()
    }

    /// Compute the laid-out content height and report it upward. Called on
    /// text change (and after the view is sized), NOT during SwiftUI's measure
    /// pass — so the reported height is a function of *content*, not of the
    /// proposed width, which is what keeps SwiftUI's layout from oscillating.
    func reportContentHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let inset = textContainerInset.height * 2
        onHeightChange?(used + inset)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? .systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        // Match NSTextView's first-line baseline using font metrics
        let ascender = font?.ascender ?? 14
        let maxW = (textContainer?.containerSize.width ?? bounds.width) - inset.width * 2
        let rect = NSRect(x: inset.width + padding,
                          y: inset.height + ascender,
                          width: maxW,
                          height: ascender + (font?.descender ?? -4) * -1)
        (placeholder as NSString).draw(with: rect, options: .truncatesLastVisibleLine, attributes: attrs)
    }
}

// MARK: - Chat Pane Click Monitor

struct ChatPaneClickMonitor: NSViewRepresentable {
    var textFieldRef: FocusableTextView?

    func makeNSView(context: Context) -> ClickMonitorView {
        let view = ClickMonitorView()
        view.textViewRef = textFieldRef
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak view] event in
            view?.handleClick(event)
            return event
        }
        context.coordinator.monitor = monitor
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: ClickMonitorView, context: Context) {
        nsView.textViewRef = textFieldRef
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var monitor: Any?
        weak var view: ClickMonitorView?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

final class ClickMonitorView: NSView {
    weak var textViewRef: FocusableTextView?

    func handleClick(_ event: NSEvent) {
        guard let window, let textView = textViewRef else { return }

        let locationInView = convert(event.locationInWindow, from: nil)
        guard bounds.contains(locationInView) else { return }

        if let clickedView = window.contentView?.hitTest(event.locationInWindow) {
            if clickedView is NSButton || clickedView is NSPopUpButton ||
               clickedView is NSSegmentedControl || clickedView is NSSlider { return }

            var ancestor: NSView? = clickedView
            while let v = ancestor {
                if v === textView { return }
                ancestor = v.superview
            }
        }

        guard window.firstResponder !== textView else { return }

        textView.isEditable = true
        let success = window.makeFirstResponder(textView)
        if !success {
            window.makeFirstResponder(nil)
            window.makeFirstResponder(textView)
        }
    }
}

#endif
