import SwiftUI

/// Shared app helpers used by the platform-specific @main entry points.
///
/// Keep @StateObject ownership in the concrete App structs. Do not wrap one
/// App inside another App (e.g. `HermesNativeApp().body`), because SwiftUI will
/// access those StateObjects before the owner is installed and create transient
/// instances.
func requestHermesNativeNotificationAuthorization() {
    Task {
        _ = await NotificationService.shared.requestAuthorization()
    }
}

#if os(macOS)
func configureHermesNativeMacApplication() {
    NSApplication.shared.setActivationPolicy(.regular)
    NSApplication.shared.activate()

    // Make the higher-order macOS window chrome rectangular and full-bleed.
    // SwiftUI's hidden-titlebar style still leaves the traffic-light area as
    // AppKit chrome; configuring NSWindow here lets Theme.background fill that
    // region instead of visually trapping the sidebar header underneath it.
    DispatchQueue.main.async {
        for window in NSApplication.shared.windows {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = true
            window.backgroundColor = NSColor(Theme.background)
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}
#endif
