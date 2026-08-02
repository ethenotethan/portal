import Foundation
import Testing
@testable import Portal

@Suite("Portal Deep Link")
internal struct HermesNativeDeepLinkTests {

    // Small matchers so tests read as intent, not as switch boilerplate.
    // PortalDeepLink has associated values and no Equatable conformance, so
    // pattern-match rather than ==.
    private func isNewSession(_ link: PortalDeepLink?) -> Bool {
        if case .newSession = link { return true }
        return false
    }

    private func isActivity(_ link: PortalDeepLink?) -> Bool {
        if case .activity = link { return true }
        return false
    }

    private func sessionID(_ link: PortalDeepLink?) -> String? {
        if case let .session(id) = link { return id }
        return nil
    }

    // MARK: - Parsing (URL -> case)

    @Test("Parses the three known hosts")
    internal func parsesKnownHosts() {
        #expect(isNewSession(PortalDeepLink(url: URL(string: "hermesnative://new-session")!)))
        #expect(isActivity(PortalDeepLink(url: URL(string: "hermesnative://activity")!)))
        #expect(sessionID(PortalDeepLink(url: URL(string: "hermesnative://session/abc123")!)) == "abc123")
    }

    @Test("Rejects a foreign or missing scheme")
    internal func rejectsForeignScheme() {
        #expect(PortalDeepLink(url: URL(string: "https://session/abc")!) == nil)
        #expect(PortalDeepLink(url: URL(string: "otherapp://new-session")!) == nil)
        // The scheme comparison is case-sensitive (Foundation preserves the
        // scheme's case rather than normalizing it), so a capitalized scheme is
        // NOT a match. Locks in the observed behavior — the app always emits the
        // lowercase canonical form, so this only rejects malformed input.
        #expect(PortalDeepLink(url: URL(string: "HERMESNATIVE://activity")!) == nil)
    }

    @Test("Rejects an unknown host")
    internal func rejectsUnknownHost() {
        #expect(PortalDeepLink(url: URL(string: "hermesnative://settings")!) == nil)
        #expect(PortalDeepLink(url: URL(string: "hermesnative://")!) == nil)
    }

    @Test("A session link with no id is not a valid link")
    internal func sessionRequiresID() {
        // Host present, path absent — there's nothing to route to.
        #expect(PortalDeepLink(url: URL(string: "hermesnative://session")!) == nil)
        #expect(PortalDeepLink(url: URL(string: "hermesnative://session/")!) == nil)
    }

    @Test("Session id is the first non-slash path component")
    internal func sessionTakesFirstPathComponent() {
        #expect(sessionID(PortalDeepLink(url: URL(string: "hermesnative://session/first/second")!)) == "first")
    }

    // MARK: - Building (case -> URL)

    @Test("Each case builds its canonical URL")
    internal func buildsCanonicalURLs() {
        #expect(PortalDeepLink.newSession.url?.absoluteString == "hermesnative://new-session")
        #expect(PortalDeepLink.activity.url?.absoluteString == "hermesnative://activity")
        #expect(PortalDeepLink.session("abc123").url?.absoluteString == "hermesnative://session/abc123")
    }

    @Test("An xOAuth link builds no URL — XAuthService owns the live callback URL")
    internal func xOAuthBuildsNoURL() {
        // The canonical URL for an OAuth callback carries ephemeral PKCE query
        // params that only XAuthService knows at redirect time, so the static
        // builder intentionally returns nil rather than emitting a stale URL.
        #expect(PortalDeepLink.xOAuth(code: "abc", state: "xyz").url == nil)
    }

    @Test("A session id with URL-reserved characters is percent-escaped when built")
    internal func buildEscapesSessionID() {
        let built = PortalDeepLink.session("a b#c").url
        #expect(built != nil)
        // The space and fragment marker must not survive raw into the URL.
        let raw = built?.absoluteString ?? ""
        #expect(!raw.contains(" "))
        #expect(!raw.contains("#"))
    }

    // MARK: - Round trip

    @Test("Build then parse recovers the original route")
    internal func roundTrips() {
        #expect(isNewSession(PortalDeepLink.newSession.url.flatMap(PortalDeepLink.init(url:))))
        #expect(isActivity(PortalDeepLink.activity.url.flatMap(PortalDeepLink.init(url:))))
        let recovered = PortalDeepLink.session("abc123").url.flatMap(PortalDeepLink.init(url:))
        #expect(sessionID(recovered) == "abc123")
    }
}
