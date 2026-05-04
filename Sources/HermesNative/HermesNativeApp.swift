import SwiftUI

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
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.background)

        // Do not hide or remove the standard close/minimize/zoom buttons.
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}
#endif
