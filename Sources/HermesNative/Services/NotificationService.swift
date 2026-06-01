import Foundation
import UserNotifications
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "NotificationService")

/// Posts local notifications for gateway events that require user action.
/// Fires when the app is backgrounded or the event is for a non-active session.
/// Suppresses notifications for the session the user is currently viewing.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()
    static var isTestEnvironment: Bool = false

    /// Set by ChatViewModel — the session the user is currently viewing.
    var activeSessionID: String? {
        didSet { UserDefaults.standard.set(activeSessionID, forKey: "hermes.notificationActiveSessionID") }
    }

    /// Whether the app is in the foreground.
    var isForegrounded: Bool = true {
        didSet { UserDefaults.standard.set(isForegrounded, forKey: "hermes.notificationIsForegrounded") }
    }

    private override init() {
        super.init()
        guard !Self.isTestEnvironment else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Call on app launch to request permission.
    func requestAuthorization() async -> Bool {
        guard !Self.isTestEnvironment else { return false }
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log.error("Authorization failed: \(error)")
            return false
        }
    }

    // MARK: - Notification Triggers

    /// Post notification for approval request.
    func notifyApproval(sessionTitle: String, command: String, sessionID: String) {
        post(
            id: "approval-\(sessionID)",
            title: "Approval Required",
            body: command.truncated(to: 80),
            subtitle: sessionTitle,
            category: .approval,
            sessionID: sessionID
        )
    }

    /// Post notification for clarify request.
    func notifyClarify(sessionTitle: String, question: String, sessionID: String) {
        post(
            id: "clarify-\(sessionID)",
            title: "Question",
            body: question.truncated(to: 80),
            subtitle: sessionTitle,
            category: .clarify,
            sessionID: sessionID
        )
    }

    /// Post notification when agent finishes a response (non-blocking, just informational).
    func notifyResponseComplete(sessionTitle: String, preview: String, sessionID: String) {
        guard responseCompleteNotificationsEnabled else { return }
        post(
            id: "complete-\(sessionID)-\(UUID().uuidString.prefix(8))",
            title: sessionTitle,
            body: preview.truncated(to: 80),
            category: .responseComplete,
            sessionID: sessionID
        )
    }

    /// Post notification for a gateway activity event.
    func notifyActivity(_ item: ActivityItem) {
        guard !item.isRead else { return }
        let prefix: String
        switch item.severity {
        case .error: prefix = "✗"
        case .warning: prefix = "⚠"
        case .info: prefix = "•"
        }
        post(
            id: "activity-\(item.id)",
            title: "\(prefix) \(item.title)",
            body: item.summary.truncated(to: 80),
            category: .activity,
            sessionID: item.sessionID
        )
    }

    /// Post notification for background task completion.
    func notifyBackgroundComplete(taskID: String, text: String) {
        post(
            id: "bg-\(taskID)",
            title: "Background Task Done",
            body: text.truncated(to: 80),
            category: .backgroundComplete,
            sessionID: nil
        )
    }

    /// Post notification when a cron job completes.
    func notifyCronComplete(jobName: String, status: String, jobID: String) {
        let statusLabel = status == "ok" ? "✓" : "✗"
        post(
            id: "cron-\(jobID)-\(UUID().uuidString.prefix(8))",
            title: "Cron: \(jobName)",
            body: "\(statusLabel) \(status)",
            category: .cronComplete,
            sessionID: nil
        )
    }

    // MARK: - Private

    private enum NotificationCategory: String {
        case approval
        case clarify
        case responseComplete
        case backgroundComplete
        case cronComplete
        case activity
    }

    private var responseCompleteNotificationsEnabled: Bool {
        UserDefaults.standard.object(forKey: SettingsViewModel.responseCompleteNotificationsKey) as? Bool ?? true
    }

    private func post(
        id: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        category: NotificationCategory,
        sessionID: String?
    ) {
        guard !Self.isTestEnvironment else { return }

        // Suppress if user is foregrounded AND viewing this session
        if isForegrounded, let sessionID, sessionID == activeSessionID {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle { content.subtitle = subtitle }
        content.sound = .default
        content.categoryIdentifier = category.rawValue
        if let sessionID {
            content.userInfo["session_id"] = sessionID
            if let url = HermesNativeDeepLink.session(sessionID).url {
                content.userInfo["url"] = url.absoluteString
            }
        }

        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: nil // Immediate
        )

        Task {
            guard await ensureAuthorizedForPosting() else { return }
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    log.error("Failed to post: \(error)")
                }
            }
        }
    }

    private func ensureAuthorizedForPosting() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await requestAuthorization()
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show notifications even when app is in foreground — but suppress for active session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let sessionID = notification.request.content.userInfo["session_id"] as? String
        let isFG = UserDefaults.standard.bool(forKey: "hermes.notificationIsForegrounded")
        let activeID = UserDefaults.standard.string(forKey: "hermes.notificationActiveSessionID")
        if isFG, let sessionID, sessionID == activeID {
            completionHandler([]) // Deliver silently, no banner/sound
        } else {
            completionHandler([.banner, .sound])
        }
    }

    /// Handle notification tap — bring the app forward and route to the
    /// relevant session via a registered URL scheme.
    ///
    /// On macOS, an in-process `NotificationCenter.post` is invisible if the
    /// process is dead and unreliable if the app is already running but not
    /// frontmost — macOS will not necessarily deliver a new process to the
    /// prior instance, and the user sees a freshly-spawned copy. Routing
    /// through the `hermesnative://` URL scheme guarantees Launch Services
    /// hands the URL to the existing app process (or launches one and
    /// delivers the URL on first run), so the user lands in the right session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionID = userInfo["session_id"] as? String
        let urlString = userInfo["url"] as? String

        Task { @MainActor in
            Self.activateAppForUserInteraction()

            if let urlString, let url = URL(string: urlString) {
                #if os(macOS)
                // Launch Services routes this to the app's .onOpenURL handler
                // in the existing process if running, or on first launch if not.
                NSWorkspace.shared.open(url)
                #else
                // iOS already activates the app and delivers .onOpenURL when
                // a notification is tapped, so this is a no-op fallback for
                // any custom deep-link path we might add later.
                UIApplication.shared.open(url)
                #endif
            } else if let sessionID {
                // Backwards-compat: notifications posted before the URL
                // scheme was wired up still carry only a session_id. Fall
                // back to the in-process post so we don't break those.
                NotificationCenter.default.post(
                    name: .hermesSwitchToSession,
                    object: nil,
                    userInfo: ["session_id": sessionID]
                )
            }
        }
        completionHandler()
    }

    /// Bring the app to the foreground. macOS will not auto-activate on a
    /// notification tap and will silently spawn a duplicate if activation
    /// is missing. We make any existing window key and order it forward.
    /// On iOS the system handles activation for us.
    @MainActor
    static func activateAppForUserInteraction() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
        #endif
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let hermesSwitchToSession = Notification.Name("hermes.switchToSession")
}
