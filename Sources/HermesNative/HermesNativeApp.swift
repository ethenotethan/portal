import SwiftUI

@main
struct HermesNativeApp: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()
    @StateObject private var personaManager = PersonaManager()

    #if os(macOS)
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }
    #endif

    var body: some Scene {
        mainWindow
        #if os(macOS)
        settingsScene
        #endif
    }

    #if os(macOS)
    private var mainWindow: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(sessionList)
                .environmentObject(personaManager)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 700)
    }

    private var settingsScene: some Scene {
        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(personaManager)
        }
    }
    #else
    private var mainWindow: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(sessionList)
                .environmentObject(personaManager)
        }
    }
    #endif
}
