import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "HermesNativeApp")

/// Shared app helpers used by the platform-specific @main entry points.
///
/// Keep @StateObject ownership in the concrete App structs. Do not wrap one
/// App inside another App (e.g. `HermesNativeApp().body`), because SwiftUI will
/// access those StateObjects before the owner is installed and create transient
/// instances.
func requestHermesNativeNotificationAuthorization() {
    Task { @MainActor in
        _ = await NotificationService.shared.requestAuthorization()
    }
}

#if os(macOS)
import AppKit

@MainActor
func configureHermesNativeMacApplication() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()
}

/// Applies the macOS window chrome configuration SwiftUI does not expose.
/// This intentionally keeps the standard red/yellow/green window controls
/// visible while allowing the app content to extend behind a transparent titlebar.
struct MacWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { configure(window: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(window: nsView.window) }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
        window.styleMask.remove(.borderless)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.background)
        window.showsResizeIndicator = false

        // Do not hide or remove the standard close/minimize/zoom buttons.
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            if let button = window.standardWindowButton(buttonType) {
                button.isHidden = false
                button.alphaValue = 1
                button.isEnabled = true
                button.superview?.isHidden = false
                button.superview?.alphaValue = 1
            }
        }

        logWindowDiagnostics(window)
    }

    private func logWindowDiagnostics(_ window: NSWindow) {
        #if DEBUG
        DispatchQueue.main.async {
            guard let w = NSApp.windows.first else { return }
            log.debug("=== HERMES WINDOW ===")
            log.debug("frame: \(String(describing: w.frame)) styleMask: \(w.styleMask.rawValue)")
            log.debug("titlebarTransparent: \(w.titlebarAppearsTransparent)")
            log.debug("titleVisibility: \(w.titleVisibility.rawValue)")
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                let b = w.standardWindowButton(kind)
                log.debug("""
                \(kind.rawValue): \
                \(String(describing: b)) \
                hidden: \(String(describing: b?.isHidden)) \
                alpha: \(String(describing: b?.alphaValue)) \
                frame: \(String(describing: b?.frame ?? .zero)) \
                superview: \(String(describing: b?.superview.map { type(of: $0) })) \
                superFrame: \(String(describing: b?.superview?.frame ?? .zero))
                """)
            }
            log.debug("=== HERMES CONTENT VIEW HIERARCHY ===")
            func dump(_ v: NSView, _ depth: Int = 0) {
                let pad = String(repeating: "  ", count: depth)
                let frameStr = String(describing: v.frame)
                let boundsStr = String(describing: v.bounds)
                log.debug("\(pad)\(type(of: v)) frame=\(frameStr) bounds=\(boundsStr) hidden=\(v.isHidden) alpha=\(v.alphaValue) subviews=\(v.subviews.count)")
                v.subviews.forEach { dump($0, depth + 1) }
            }
            if let cv = w.contentView { dump(cv) }
        }
        #endif
    }
}
#endif
