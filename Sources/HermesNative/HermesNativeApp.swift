import SwiftUI

@main
struct HermesNativeApp: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()

    init() {
        // Required for bare SPM binaries — macOS won't activate
        // a process without a proper .app bundle otherwise.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(sessionList)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 700)

        Settings {
            SettingsView()
                .environmentObject(settings)
        }
    }
}
