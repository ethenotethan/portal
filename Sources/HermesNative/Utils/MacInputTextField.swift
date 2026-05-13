#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - MacInputTextField

/// A native NSTextField wrapper that fixes the broken SwiftUI/AppKit focus
/// bridging on macOS.
///
/// ## The Problem
/// SwiftUI's `TextField` on macOS is backed by an `NSTextField`, but SwiftUI
/// does not reliably call `window.makeFirstResponder(_:)` when the user clicks
/// the field after the sidebar (an `NSTableView` in `NavigationSplitView`) has
/// stolen first-responder. SwiftUI's `@FocusState` and `TapGesture` both fail
/// because the NSScrollView / NSSplitView absorbs the mouseDown event before
/// SwiftUI's gesture system processes it.
///
/// ## The Fix
/// 1. The native `NSTextField` handles click-to-focus via its own `mouseDown`
///    override — calling `window.makeFirstResponder(self)` directly.
/// 2. When `@FocusState` becomes `true` (e.g. from session switch or
///    the chat-pane click monitor), `updateNSView` calls
///    `window.makeFirstResponder(nsView)` directly.
/// 3. `ChatPaneClickMonitor` uses `NSEvent.addLocalMonitorForEvents` to detect
///    clicks anywhere in the chat detail pane and restore focus — this sees
///    events before any SwiftUI gesture or AppKit view can consume them.
struct MacInputTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var isFocused: FocusState<Bool>.Binding
    @Binding var fieldRef: FocusableTextField?
    var onSubmit: () -> Void
    var onImagePaste: ([NSItemProvider]) -> Void

    func makeNSView(context: Context) -> FocusableTextField {
        let tf = FocusableTextField()
        tf.placeholderString = placeholder
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: 15, weight: .regular)
        tf.usesSingleLineMode = true
        tf.cell?.isScrollable = true
        tf.lineBreakMode = .byTruncatingTail
        tf.delegate = context.coordinator
        tf.onSubmit = onSubmit
        tf.onImagePaste = onImagePaste
        tf.setAccessibilityIdentifier("chatInput")
        context.coordinator.textField = tf
        // Propagate the reference back to ChatView for ChatPaneClickMonitor
        DispatchQueue.main.async {
            fieldRef = tf
        }
        return tf
    }

    func updateNSView(_ nsView: FocusableTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.onSubmit = onSubmit
        nsView.onImagePaste = onImagePaste

        // Keep the reference current in case the view was recycled
        if fieldRef !== nsView {
            DispatchQueue.main.async {
                fieldRef = nsView
            }
        }

        // Only drive AppKit first-responder on a true → false transition.
        // Calling makeFirstResponder on every updateNSView (e.g. every
        // keystroke via the text binding) causes a focus fight that can
        // drop the caret or break editing state.
        let nowFocused = isFocused.wrappedValue
        if nowFocused && !context.coordinator.wasFocused {
            makeFirstResponder(nsView)
        }
        context.coordinator.wasFocused = nowFocused
    }

    private func makeFirstResponder(_ nsView: FocusableTextField) {
        let attempt: () -> Void = { [weak nsView] in
            guard let nsView, let window = nsView.window else { return }
            let editor = nsView.currentEditor() ?? nsView
            guard window.firstResponder !== editor else { return }
            nsView.isEditable = true
            nsView.isSelectable = true
            window.makeFirstResponder(nil)
            window.makeFirstResponder(nsView)
        }
        DispatchQueue.main.async(execute: attempt)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacInputTextField
        weak var textField: FocusableTextField?
        /// Tracks the previous SwiftUI focus-state value so updateNSView only
        /// calls makeFirstResponder on a false→true transition, not on every
        /// keystroke while already focused.
        var wasFocused: Bool = false

        init(_ parent: MacInputTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.isFocused.wrappedValue = false
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

// MARK: - FocusableTextField

/// Custom `NSTextField` that:
/// - Overrides `mouseDown` to force `becomeFirstResponder` (fixes click-to-focus)
/// - Intercepts ⌘V paste for image content
final class FocusableTextField: NSTextField {
    var onSubmit: (() -> Void)?
    var onImagePaste: (([NSItemProvider]) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let window else { return }
        let editor = currentEditor() ?? self
        guard window.firstResponder !== editor else { return }
        let attempt: () -> Void = { [weak self] in
            guard let self, let window = self.window else { return }
            let editor = self.currentEditor() ?? self
            guard window.firstResponder !== editor else { return }
            self.isEditable = true
            self.isSelectable = true
            let success = window.makeFirstResponder(self)
            if !success {
                window.makeFirstResponder(nil)
                window.makeFirstResponder(self)
            }
        }
        DispatchQueue.main.async(execute: attempt)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Intercept ⌘V for image paste
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            let pb = NSPasteboard.general
            if pb.canReadObject(forClasses: [NSImage.self, NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) {
                var providers: [NSItemProvider] = []

                // Check for file URLs (image files)
                if let urls = pb.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                    let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff", "heic", "heif"]
                    for url in urls where imageExts.contains(url.pathExtension.lowercased()) {
                        if let provider = NSItemProvider(contentsOf: url) {
                            providers.append(provider)
                        }
                    }
                }

                // Check for image data on pasteboard
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
}

// MARK: - Chat Pane Click Monitor

/// Monitors mouse clicks in the chat detail pane and restores focus to the
/// input text field. Uses `NSEvent.addLocalMonitorForEvents` which sees ALL
/// mouse events **before** any SwiftUI gesture or AppKit view can consume them.
///
/// Place this as a `.background` on the chat content ZStack. It uses the
/// NSView's bounds to determine whether a click is inside the chat pane
/// (vs. the sidebar).
struct ChatPaneClickMonitor: NSViewRepresentable {
    var textFieldRef: FocusableTextField?

    func makeNSView(context: Context) -> ClickMonitorView {
        let view = ClickMonitorView()
        view.textFieldRef = textFieldRef
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak view] event in
            view?.handleClick(event)
            return event  // Always propagate — never consume
        }
        context.coordinator.monitor = monitor
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: ClickMonitorView, context: Context) {
        nsView.textFieldRef = textFieldRef
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var monitor: Any?
        weak var view: ClickMonitorView?

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

final class ClickMonitorView: NSView {
    weak var textFieldRef: FocusableTextField?

    func handleClick(_ event: NSEvent) {
        guard let window, let textField = textFieldRef else { return }

        // Only respond to clicks inside this chat pane
        let locationInView = convert(event.locationInWindow, from: nil)
        guard bounds.contains(locationInView) else { return }

        // Don't steal focus if the user clicked on the text field itself
        if let clickedView = window.contentView?.hitTest(event.locationInWindow) {
            // Allow buttons/controls to keep focus
            if clickedView is NSButton || clickedView is NSPopUpButton ||
               clickedView is NSSegmentedControl || clickedView is NSSlider { return }

            var ancestor: NSView? = clickedView
            while let v = ancestor {
                if v === textField { return }
                ancestor = v.superview
            }
        }

        // Already focused? Nothing to do.
        let editor = textField.currentEditor() ?? textField
        guard window.firstResponder !== editor else { return }

        textField.isEditable = true
        textField.isSelectable = true
        let success = window.makeFirstResponder(textField)
        if !success {
            window.makeFirstResponder(nil)
            window.makeFirstResponder(textField)
        }
    }
}

#endif
