import Foundation

/// Routes that the app responds to via the `hermesnative://` URL scheme.
///
/// All URLs flow into SwiftUI's `.onOpenURL` handler in `ContentView` and are
/// dispatched by `handleDeepLink(_:)`. NotificationService embeds a deep-link
/// URL in every posted notification's `userInfo` so taps route through Launch
/// Services to the running app process instead of spawning a duplicate.
enum HermesNativeDeepLink {
    case newSession
    case session(String)
    case activity

    init?(url: URL) {
        guard url.scheme == "hermesnative" else { return nil }
        switch url.host {
        case "new-session":
            self = .newSession
        case "session":
            // hermesnative://session/<id>
            if let id = url.pathComponents.first(where: { $0 != "/" }), !id.isEmpty {
                self = .session(id)
            } else {
                return nil
            }
        case "activity":
            self = .activity
        default:
            return nil
        }
    }

    /// Build the canonical URL for this deep link.
    var url: URL? {
        switch self {
        case .newSession:
            return URL(string: "hermesnative://new-session")
        case .session(let id):
            let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            return URL(string: "hermesnative://session/\(escaped)")
        case .activity:
            return URL(string: "hermesnative://activity")
        }
    }
}
