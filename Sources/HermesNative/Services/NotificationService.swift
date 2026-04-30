import Foundation
import UserNotifications

/// Posts local notifications for gateway events that require user action.
/// Fires when the app is backgrounded or the event is for a non-active session.
@MainActor
final class NotificationService: NSObject, ObservableObject {
    static let shared = NotificationService()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Call on app launch to request permission.
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            NSLog("[NotificationService] Authorization failed: \(error)")
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
        post(
            id: "complete-\(sessionID)-\(UUID().uuidString.prefix(8))",
            title: sessionTitle,
            body: preview.truncated(to: 80),
            category: .responseComplete,
            sessionID: sessionID
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

    // MARK: - Private

    private enum NotificationCategory: String {
        case approval
        case clarify
        case responseComplete
        case backgroundComplete
    }

    private func post(
        id: String,
        title: String,
        body: String,
        subtitle: String? = nil,
        category: NotificationCategory,
        sessionID: String?
    ) {
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

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("[NotificationService] Failed to post: \(error)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationService: UNUserNotificationCenterDelegate {
    /// Show notifications even when app is in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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
