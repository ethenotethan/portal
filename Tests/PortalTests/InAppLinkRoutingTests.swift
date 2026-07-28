import Testing
import Foundation
@testable import Portal

/// Guards the root `OpenURLAction` interceptor in `ContentView`, which decides
/// whether an in-app link is routed IN-PROCESS or handed to the system.
///
/// The interceptor's branch is exactly `PortalDeepLink(url:) != nil`:
///   • a recognized `hermesnative://` URL → `handleDeepLink` (`.handled`)
///   • anything else → `.systemAction` (browser, mail, Finder…)
///
/// Without this, a plain SwiftUI `Link`/`openURL` for the app's own scheme —
/// e.g. an activity item's "Open Session" external ref in the notifications
/// tab — falls through to the default action (NSWorkspace.open on macOS).
/// Because `hermesnative` is a registered scheme, Launch Services bounces the
/// URL back out and spawns a SECOND app instance. These tests pin the routing
/// decision so that regression can't creep back in.
@Suite("In-app link routing")
struct InAppLinkRoutingTests {

    /// Mirror of the interceptor's predicate: true ⇒ handled in-process,
    /// false ⇒ deferred to `.systemAction`.
    private func isRoutedInProcess(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return PortalDeepLink(url: url) != nil
    }

    @Test("app-scheme session links are intercepted, not sent to the OS")
    func sessionLinkIntercepted() {
        // The exact shape an activity "Open Session" external ref would carry.
        #expect(isRoutedInProcess("hermesnative://session/20260101_000000_abcdef"))
        #expect(isRoutedInProcess("hermesnative://session/722745ed"))
    }

    @Test("all app-scheme routes are intercepted")
    func allAppRoutesIntercepted() {
        #expect(isRoutedInProcess("hermesnative://new-session"))
        #expect(isRoutedInProcess("hermesnative://activity"))
    }

    @Test("external URLs defer to the system, never intercepted")
    func externalLinksDeferToSystem() {
        #expect(!isRoutedInProcess("https://example.com/article"))
        #expect(!isRoutedInProcess("http://10.0.2.47:8642/health"))
        #expect(!isRoutedInProcess("mailto:someone@example.com"))
        #expect(!isRoutedInProcess("file:///tmp/report.log"))
    }

    @Test("malformed app-scheme URLs defer to the system rather than mis-route")
    func malformedAppLinksDeferToSystem() {
        // Right scheme, unknown host / missing id — not a recognized route, so
        // the interceptor must NOT claim it (falls through to .systemAction).
        #expect(!isRoutedInProcess("hermesnative://unknown-host"))
        #expect(!isRoutedInProcess("hermesnative://session/"))
    }
}
