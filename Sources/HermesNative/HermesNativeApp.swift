import SwiftUI

@main
struct HermesNativeApp: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()

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
