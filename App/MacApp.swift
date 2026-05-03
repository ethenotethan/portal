import SwiftUI

@main
struct HermesNativeAppMac: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()
    @StateObject private var personaManager = PersonaManager()
    @StateObject private var spawnTreeStore = SpawnTreeStore()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()

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
                .background(MacWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 700)

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(personaManager)
        }
    }
}
