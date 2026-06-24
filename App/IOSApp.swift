import SwiftUI

@main
struct HermesNativeAppIOS: App {
    @StateObject private var settings = SettingsViewModel()
    @StateObject private var sessionList = SessionListViewModel()
    @StateObject private var personaManager = PersonaManager()
    @StateObject private var spawnTreeStore = SpawnTreeStore()
    @StateObject private var gatewayClientWrapper = GatewayClientWrapper()
    @StateObject private var capabilitiesStore = HermesCapabilitiesStore()
    @StateObject private var celebrationManager = CelebrationManager.shared
    @StateObject private var ttsService = TTSService.shared

    init() {
        requestHermesNativeNotificationAuthorization()
        startHermesNativePerfInstrumentation()
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
                .perfOverlay()
        }
    }
}
