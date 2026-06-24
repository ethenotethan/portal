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

    /// Width grid (pt) for quantizing layout proposals. Neighboring proposed
    /// widths snap to the same bucket so `sizeThatFits` returns a stable height
    /// and SwiftUI's layout reaches a fixed point instead of oscillating.
    private static let widthQuantum: CGFloat = 8

    func makeNSView(context: Context) -> NSScrollView {
        let tv = FocusableTextView()
        tv.placeholder = placeholder
        tv.maxLines = maxLines
        tv.font = .systemFont(ofSize: 15, weight: .regular)
        tv.delegate = context.coordinator
        tv.onSubmit = onSubmit
        tv.onImagePaste = onImagePaste
        tv.onHeightChange = { height in
            context.coordinator.parentHeight = height
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
        }
        nsView.placeholder = placeholder
        nsView.onSubmit = onSubmit
        nsView.onImagePaste = onImagePaste
        nsView.onHeightChange = { height in
            context.coordinator.parentHeight = height
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
        // This must be PURE: mutating the live NSTextView here invalidates
        // its layout mid-pass, which schedules another SwiftUI transaction
        // with a slightly different proposed width — an infinite layout loop
        // that hangs the main thread. Measure with an offscreen TextKit
        // stack instead; the live view's container tracks its frame width
        // on its own (widthTracksTextView).
        guard let nsView = scrollView.documentView as? FocusableTextView else { return nil }
        let coordinator = context.coordinator

        // Backstop: if sizeThatFits is hammered many times in one runloop tick,
        // width quantization didn't converge for this content — stop measuring
        // and return the last/empty height so the main thread can't spin. The
        // counter resets at the end of the tick.
        coordinator.passCount += 1
        if !coordinator.passResetScheduled {
            coordinator.passResetScheduled = true
            DispatchQueue.main.async {
                coordinator.passCount = 0
                coordinator.passResetScheduled = false
            }
        }
        if coordinator.passCount > 32, let last = coordinator.cachedSize {
            return last
        }

        let width: CGFloat
        if let w = proposal.width, w.isFinite, w > 0 {
            // Quantize the width into coarse buckets so height is a STEP
            // function of width. SwiftUI re-proposes widths that drift by a
            // fraction or a point between passes; without bucketing every pass
            // is a new MeasureKey → a fresh O(n) measurement → a slightly
            // different height → an ancestor reflow → another width → an
            // infinite layout loop pegging the main thread (the recurring
            // beachball). Snapping to an 8pt grid makes neighboring widths
            // collapse to one cache entry, so fixed-point layout converges in
            // a single step. This is the convergence guarantee the earlier
            // "single height authority" fixes lacked.
            width = (w / Self.widthQuantum).rounded(.down) * Self.widthQuantum
        } else {
            width = coordinator.lastMeasuredWidth ?? 300
        }

        let font = nsView.font ?? .systemFont(ofSize: 15, weight: .regular)
        let lineHeight = font.boundingRectForFont.height
        let maxHeight = lineHeight * CGFloat(nsView.maxLines)
        let text = nsView.string

        // Huge pastes: once the text can't possibly fit under maxLines the
        // height is the cap regardless — skip the O(n) layout measurement.
        let minPossibleLines = (text.count / 600) + text.lazy.filter { $0 == "\n" }.count
        if minPossibleLines > nsView.maxLines * 4 {
            coordinator.lastMeasuredWidth = width
            return CGSize(width: width, height: maxHeight)
        }

        let key = Coordinator.MeasureKey(
            width: width,
            textHash: text.hashValue,
            maxLines: nsView.maxLines
        )
        if let cached = coordinator.cachedSize, coordinator.cachedKey == key {
            return cached
        }

        let inset = nsView.textContainerInset
        let textHeight = coordinator.measurer.height(
            for: text,
            font: font,
            width: max(width - inset.width * 2, 50)
        )
        let cappedHeight = min(max(textHeight, lineHeight) + 12, maxHeight)
        let result = CGSize(width: width, height: cappedHeight)
        coordinator.lastMeasuredWidth = width
        coordinator.cachedKey = key
        coordinator.cachedSize = result
        return result
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        struct MeasureKey: Equatable {
            let width: CGFloat
            let textHash: Int
            let maxLines: Int
        }

        var parent: MacInputTextField
        weak var textView: FocusableTextView?
        var wasFocused: Bool = false
        var parentHeight: CGFloat = 0
        var lastMeasuredWidth: CGFloat?
        var cachedKey: MeasureKey?
        var cachedSize: CGSize?
        let measurer = TextHeightMeasurer()
        /// Backstop against a runaway layout pass: counts sizeThatFits calls
        /// within a single runloop tick. If width quantization ever fails to
        /// converge, this caps the damage at a fixed height instead of a hang.
        var passCount = 0
        var passResetScheduled = false

        init(_ parent: MacInputTextField) {
            self.parent = parent
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

// MARK: - TextHeightMeasurer

/// Offscreen TextKit stack for measuring wrapped text height without
/// touching the live NSTextView (whose mutation mid-layout loops SwiftUI).
final class TextHeightMeasurer {
    private let layoutManager = NSLayoutManager()
    private let textContainer = NSTextContainer(size: .zero)
    private let textStorage = NSTextStorage()

    // PROCESS-WIDE measurement cache, keyed by (text, quantized width, font
    // size). The per-Coordinator cache is not enough: SwiftUI can rebuild the
    // NSViewRepresentable (and thus its Coordinator) on every layout pass, so a
    // coordinator-local cache resets to empty each iteration and the expensive
    // O(n) TextKit measurement re-runs forever — the recurring beachball. A
    // static cache survives coordinator churn, so a given (text,width) is
    // measured at most once and every later pass returns instantly, which is
    // what actually breaks the layout loop.
    private struct Key: Hashable {
        let textHash: Int
        let width: Int
        let fontSize: Int
    }
    private static let cacheLock = NSLock()
    // nonisolated(unsafe): access is hand-synchronized via cacheLock below, so
    // the compiler's Swift 6 global-mutable-state check (which the SwiftPM CI
    // build enforces strictly) is satisfied manually.
    nonisolated(unsafe) private static var cache: [Key: CGFloat] = [:]

    init() {
        textContainer.lineFragmentPadding = 2
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
    }

    func height(for text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let key = Key(textHash: text.hashValue,
                      width: Int(width.rounded()),
                      fontSize: Int(font.pointSize.rounded()))
        Self.cacheLock.lock()
        if let hit = Self.cache[key] {
            Self.cacheLock.unlock()
            return hit
        }
        Self.cacheLock.unlock()

        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textStorage.setAttributedString(
            NSAttributedString(string: text.isEmpty ? " " : text, attributes: [.font: font])
        )
        layoutManager.ensureLayout(for: textContainer)
        let measured = layoutManager.usedRect(for: textContainer).height

        Self.cacheLock.lock()
        // Bound the cache so a long session of distinct inputs can't grow it
        // without limit; the working set per field is tiny.
        if Self.cache.count > 512 { Self.cache.removeAll(keepingCapacity: true) }
        Self.cache[key] = measured
        Self.cacheLock.unlock()
        return measured
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
        // NOTE: do NOT call invalidateIntrinsicContentSize() and do NOT
        // override intrinsicContentSize. Height is owned solely by the
        // SwiftUI representable's sizeThatFits (offscreen measurement). A
        // second AppKit-side height authority here fights it: the live
        // intrinsic size nudges the scroll view, SwiftUI re-proposes a
        // width, the two never converge, and the main thread spins in
        // layout forever. The NSTextView still grows to fit its content
        // inside the scroll view via isVerticallyResizable + width tracking.
        onTextChange?(string)
        scrollRangeToVisible(selectedRange())
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
