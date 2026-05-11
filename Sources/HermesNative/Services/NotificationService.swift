import Foundation
import UserNotifications
import os

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
        if let sessionID { content.userInfo["session_id"] = sessionID }

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

    /// Handle notification tap — switch to the relevant session.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let sessionID = userInfo["session_id"] as? String {
            Task { @MainActor in
                // Post a notification that ContentView can observe
                NotificationCenter.default.post(
                    name: .hermesSwitchToSession,
                    object: nil,
                    userInfo: ["session_id": sessionID]
                )
            }
        }
        completionHandler()
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let hermesSwitchToSession = Notification.Name("hermes.switchToSession")
}
