import Testing
import Foundation
@testable import Portal

/// X OAuth (PKCE) primitives and the API/URL mappings behind the sign-in.
@Suite("X OAuth")
internal struct XOAuthTests {

    @Test("PKCE challenge matches the RFC 7636 test vector")
    internal func challengeVector() {
        // RFC 7636 §B: verifier → S256 challenge.
        #expect(
            XAuthService.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test("Verifier/state are URL-safe and the right length")
    internal func verifierShape() {
        let verifier = XAuthService.makeVerifier()
        #expect(verifier.count == 64)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
        let state = XAuthService.makeState()
        #expect(state.count == 24)
        #expect(state.allSatisfy { $0.isLetter || $0.isNumber })
    }

    @Test("Deep link parses the x-oauth callback; junk rejected")
    internal func deepLink() {
        let good = PortalDeepLink(url: URL(string: "hermesnative://x-oauth?code=abc123&state=xyz")!)
        #expect(good == .xOAuth(code: "abc123", state: "xyz"))
        #expect(PortalDeepLink(url: URL(string: "hermesnative://x-oauth?state=xyz")!) == nil)
        #expect(PortalDeepLink(url: URL(string: "hermesnative://other?code=a&state=b")!) == nil)
        #expect(PortalDeepLink(url: URL(string: "https://x.com/callback?code=a&state=b")!) == nil)
    }

    @Test("public_metrics maps to all four action-bar counts")
    internal func metrics() {
        let m = XAPIClient.mapMetrics([
            "reply_count": 12, "retweet_count": 48,
            "like_count": 1204, "impression_count": 22_000,
        ])
        #expect(m?.replies == 12)
        #expect(m?.reposts == 48)
        #expect(m?.likes == 1204)
        #expect(m?.views == 22_000)
        #expect(XAPIClient.mapMetrics(nil) == nil)
    }

    @Test("A refresh response without a new refresh token keeps the old one")
    internal func refreshMerge() {
        let old = XTokens(accessToken: "a1", refreshToken: "r1",
                          expiresAt: Date().addingTimeInterval(-10))
        let refreshed = XTokens(accessToken: "a2", refreshToken: "",
                                expiresAt: Date().addingTimeInterval(7200))
        let merged = refreshed.mergingRefresh(from: old)
        #expect(merged.accessToken == "a2")
        #expect(merged.refreshToken == "r1")
    }
}
