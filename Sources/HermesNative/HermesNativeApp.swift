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
}
#endif
