import Foundation

/// Navigation seam for "an intent ran as a session — click into it."
///
/// When `artifact.action.invoke` returns a `session_id`, the gateway ran the
/// intent as a contained agent session rather than a one-off. The trusted
/// native status chrome offers click-through into that live run. Navigation
/// reuses the same in-process `hermesSwitchToSession` notification the sidebar,
/// inbox, and notification taps use — `ContentView` observes it and resolves
/// the runtime-or-database session ID before selecting the row. The untrusted
/// HTML page is never handed a session ID or any navigation capability; only
/// this native code posts the switch.
internal enum ArtifactIntentSessionLink {
    /// Build the notification name + payload for switching to `sessionID`.
    /// Pure and side-effect-free so the mapping can be unit-tested without a
    /// running `NotificationCenter` observer.
    internal static func switchNotification(
        sessionID: String
    ) -> (name: Notification.Name, userInfo: [String: String])? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (.hermesSwitchToSession, ["session_id": trimmed])
    }

    /// Post the in-process session-switch for `sessionID`. A blank ID is a
    /// no-op (never posts an unusable switch).
    internal static func open(
        sessionID: String,
        center: NotificationCenter = .default
    ) {
        guard let notification = switchNotification(sessionID: sessionID) else { return }
        center.post(name: notification.name, object: nil, userInfo: notification.userInfo)
    }
}
