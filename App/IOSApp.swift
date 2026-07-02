import SwiftUI
import UIKit

@main
struct HermesNativeAppIOS: App {
    @UIApplicationDelegateAdaptor(HermesNativeIOSAppDelegate.self) private var appDelegate
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

/// UIKit-level hooks for APNs device-token registration. Remote notification
/// payloads carry `session_id` in userInfo, so taps route through the same
/// UNUserNotificationCenter delegate path as local notifications.
final class HermesNativeIOSAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Ask the OS for an APNs device token. Fails silently in the
        // simulator or without the push entitlement — local notifications
        // keep working either way.
        PushRegistrationService.requestDeviceToken()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        PushRegistrationService.shared.store(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        PushRegistrationService.shared.registrationFailed(error)
    }
}
