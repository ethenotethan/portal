import SwiftUI

@main
struct HermesNativeApp: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()
    @StateObject private var personaManager = PersonaManager()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(sessionList)
                .environmentObject(personaManager)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 700)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(personaManager)
        }
    }
}
