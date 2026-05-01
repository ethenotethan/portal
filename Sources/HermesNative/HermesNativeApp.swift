import SwiftUI

/// Shared app definition — used by the Xcode app targets' @main entry points.
/// macOS: HermesNativeAppMac (@main) → this as body
/// iOS:   HermesNativeAppIOS (@main) → this as body
struct HermesNativeApp: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()
    @StateObject private var personaManager = PersonaManager()
    @StateObject private var spawnTreeStore = SpawnTreeStore()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()

    #if os(macOS)
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        Task {
            _ = await NotificationService.shared.requestAuthorization()
        }
    }
    #else
    init() {
        Task {
            _ = await NotificationService.shared.requestAuthorization()
        }
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
                .environmentObject(spawnTreeStore)
                .environmentObject(gatewayClientWrapper)
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
                .environmentObject(spawnTreeStore)
                .environmentObject(gatewayClientWrapper)
        }
    }
    #endif
}