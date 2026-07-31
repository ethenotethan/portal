import Foundation

/// Routes that the app responds to via the `hermesnative://` URL scheme.
///
/// All URLs flow into SwiftUI's `.onOpenURL` handler in `ContentView` and are
/// dispatched by `handleDeepLink(_:)`. NotificationService embeds a deep-link
/// URL in every posted notification's `userInfo` so taps route through Launch
/// Services to the running app process instead of spawning a duplicate.
internal enum PortalDeepLink: Equatable {
    case newSession
    case session(String)
    case activity
    /// X OAuth 2.0 (PKCE) callback: hermesnative://x-oauth?code=…&state=…
    case xOAuth(code: String, state: String)

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
        case "x-oauth":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard let code = items?.first(where: { $0.name == "code" })?.value, !code.isEmpty,
                  let state = items?.first(where: { $0.name == "state" })?.value, !state.isEmpty else {
                return nil
            }
            self = .xOAuth(code: code, state: state)
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
        case .xOAuth:
            return nil   // built by XAuthService with live query params
        }
    }
}
