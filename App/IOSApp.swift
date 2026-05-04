import SwiftUI

@main
struct HermesNativeAppIOS: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()
    @StateObject private var personaManager = PersonaManager()
    @StateObject private var spawnTreeStore = SpawnTreeStore()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()
    @StateObject private var capabilitiesStore = HermesCapabilitiesStore()

    init() {
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
        }
    }
}
