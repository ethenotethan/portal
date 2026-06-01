import SwiftUI
import AppKit

@main
struct HermesNativeAppMac: App {
    @NSApplicationDelegateAdaptor(HermesNativeAppDelegate.self) private var appDelegate
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()
    @StateObject private var personaManager = PersonaManager()
    @StateObject private var spawnTreeStore = SpawnTreeStore()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()
    @StateObject private var capabilitiesStore = HermesCapabilitiesStore()
    @StateObject private var celebrationManager = CelebrationManager.shared
    @StateObject private var ttsService = TTSService.shared

    init() {
        configureHermesNativeMacApplication()
        requestHermesNativeNotificationAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(sessionList)
                .environmentObject(personaManager)
                .environmentObject(spawnTreeStore)
                .environmentObject(gatewayClientWrapper)
                .environmentObject(capabilitiesStore)
                .environmentObject(celebrationManager)
                .environmentObject(ttsService)
                .background(MacWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 700)
        .commands {
            // Keep the app alive when the last window closes so notifications
            // (approval requests, cron completions) still surface in the menu bar.
            CommandGroup(replacing: .appTermination) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(personaManager)
                .environmentObject(capabilitiesStore)
        }
    }
}

/// AppKit-level hooks that SwiftUI doesn't expose directly.
///
/// Two responsibilities matter for the notification / deep-link fix:
///   1. `applicationShouldHandleReopen` — when the user clicks the Dock icon
///      or re-activates a hidden window, bring it back to the front. Without
///      this, the running app can sit behind other windows and the user
///      perceives a "nothing happened" tap.
///   2. `application(_:open:)` is the AppKit-level entry point for
///      `hermesnative://` URLs. SwiftUI's `.onOpenURL` already handles this,
///      but having the delegate in place keeps the activation flow reliable
///      across the whole app lifecycle.
final class HermesNativeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // Reopen the main window group if every window was closed.
            for window in NSApp.windows {
                window.makeKeyAndOrderFront(nil)
            }
        } else {
            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // SwiftUI's .onOpenURL handles routing, but we still need to ensure
        // the running app is the active one so the user sees the result.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Stay alive in the background so notification permission and the
        // gateway WebSocket remain functional. The user can quit explicitly
        // via Cmd-Q. (AppKit's default is true; we override to false.)
        false
    }
}
