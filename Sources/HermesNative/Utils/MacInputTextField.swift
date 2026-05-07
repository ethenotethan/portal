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
        // Update text only when changed externally (avoid overwriting while typing)
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        nsView.onSubmit = onSubmit
        nsView.onImagePaste = onImagePaste

        // When @FocusState becomes true, force firstResponder via AppKit.
        // This bypasses SwiftUI's broken focus bridging entirely.
        if isFocused.wrappedValue {
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                let editor = nsView.currentEditor() ?? nsView
                if window.firstResponder !== editor {
                    window.makeFirstResponder(nsView)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MacInputTextField
        weak var textField: FocusableTextField?

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
            // Only clear focus if we're not about to re-focus
            DispatchQueue.main.async {
                if let window = self.textField?.window,
                   window.firstResponder !== self.textField?.currentEditor() {
                    self.parent.isFocused.wrappedValue = false
                }
            }
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

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        // CRITICAL: Force firstResponder on click.
        // SwiftUI's bridged TextField doesn't do this reliably after the
        // sidebar steals firstResponder.
        if let window {
            let editor = currentEditor() ?? self
            if window.firstResponder !== editor {
                window.makeFirstResponder(self)
            }
        }
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
        guard let window,
              let textField = textFieldRef else { return }

        // Convert click location to our view's coordinate space
        let locationInWindow = event.locationInWindow
        let locationInView = convert(locationInWindow, from: nil)

        // Only act on clicks within our bounds (the chat detail pane)
        guard bounds.contains(locationInView) else { return }

        // Check what was actually clicked
        if let clickedView = window.contentView?.hitTest(locationInWindow) {
            // Don't steal focus from buttons, menus, or other interactive controls
            // that the user intentionally clicked
            if clickedView is NSButton { return }
            if clickedView is NSPopUpButton { return }
            if clickedView is NSSegmentedControl { return }
            if clickedView is NSSlider { return }

            // Don't steal focus if the click was on the text field itself
            // (it handles its own focus via mouseDown)
            var ancestor: NSView? = clickedView
            while let v = ancestor {
                if v === textField { return }
                ancestor = v.superview
            }
        }

        // Click was in the chat pane but not on the text field or a button.
        // Restore focus to the text field.
        let editor = textField.currentEditor() ?? textField
        if window.firstResponder !== editor {
            window.makeFirstResponder(textField)
        }
    }
}

#endif
