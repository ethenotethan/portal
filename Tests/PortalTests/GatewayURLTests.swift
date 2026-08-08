import Foundation
import Testing
@testable import Portal

/// Covers the address forms a Tailscale user actually types. Every case here
/// failed before `GatewayURL` existed: `URL(string:)` returns nil for a bare
/// `host:port` with a path, and — worse — succeeds with a nil host when the
/// address is a MagicDNS name, because `my-box.ts.net:8642` parses as
/// `scheme:opaque`.
@Suite("Gateway URL normalization")
internal struct GatewayURLTests {
    // MARK: - Tailnet addresses

    @Test("a bare tailnet IP and port becomes a ws URL")
    internal func normalizesBareTailnetAddress() throws {
        let url = try #require(GatewayURL.normalize("100.94.3.17:8642"))
        #expect(url.scheme == "ws")
        #expect(url.host == "100.94.3.17")
        #expect(url.port == 8642)
        #expect(url.path == "/v1/ws")
    }

    @Test("a MagicDNS name keeps its host instead of becoming the scheme")
    internal func magicDNSNameKeepsHost() throws {
        let url = try #require(GatewayURL.normalize("my-box.tail1a2b3.ts.net:8642"))
        // The regression: URL(string:) parsed this with scheme == the hostname
        // and host == nil, so the socket dialed nothing and nothing reported it.
        #expect(url.scheme == "ws")
        #expect(url.host == "my-box.tail1a2b3.ts.net")
        #expect(url.port == 8642)
    }

    @Test("an explicit ws path is not doubled")
    internal func doesNotDoubleTheSocketPath() throws {
        let url = try #require(GatewayURL.normalize("100.94.3.17:8642/v1/ws"))
        #expect(url.absoluteString == "ws://100.94.3.17:8642/v1/ws")
    }

    @Test("the Standard sidecar path is left alone")
    internal func preservesStandardSidecarPath() throws {
        let url = try #require(GatewayURL.normalize("http://100.94.3.17:8080/api/ws"))
        #expect(url.absoluteString == "ws://100.94.3.17:8080/api/ws")
    }

    // MARK: - Scheme inference

    @Test("a public host with no scheme gets TLS, a private one does not")
    internal func infersSchemeFromReachability() throws {
        // A tailnet is already encrypted end-to-end and the harness listens on
        // plain HTTP there, so defaulting to wss would reject the likeliest input.
        #expect(try #require(GatewayURL.normalize("100.94.3.17:8642")).scheme == "ws")
        #expect(try #require(GatewayURL.normalize("my-box.ts.net:8642")).scheme == "ws")
        #expect(try #require(GatewayURL.normalize("gateway.example.com")).scheme == "wss")
    }

    @Test("http and https map onto ws and wss")
    internal func canonicalizesHTTPSchemes() throws {
        #expect(try #require(GatewayURL.normalize("https://g.example.com/v1/ws")).scheme == "wss")
        #expect(try #require(GatewayURL.normalize("http://127.0.0.1:8642/v1/ws")).scheme == "ws")
        #expect(try #require(GatewayURL.normalize("wss://g.example.com/v1/ws")).scheme == "wss")
    }

    @Test("unusable addresses are rejected rather than defaulted")
    internal func rejectsUnusableAddresses() {
        // Nil has to stay nil: falling back to a default is precisely how a
        // tailnet address turned into localhost.
        #expect(GatewayURL.normalize("") == nil)
        #expect(GatewayURL.normalize("   ") == nil)
        #expect(GatewayURL.normalize("ftp://example.com") == nil)
        #expect(GatewayURL.normalize("ws://") == nil)
    }

    // MARK: - Private-network classification

    @Test("Tailscale's CGNAT range counts as private")
    internal func treatsCGNATAsPrivate() {
        // 100.64.0.0/10 — RFC 6598, which is what Tailscale assigns from. This
        // gated the Connect button: a tailnet host judged public demanded a
        // Cloudflare Access cookie that was never coming.
        #expect(GatewayURL.isPrivateHost("100.64.0.1"))
        #expect(GatewayURL.isPrivateHost("100.94.3.17"))
        #expect(GatewayURL.isPrivateHost("100.127.255.254"))
    }

    @Test("addresses just outside the CGNAT range stay public")
    internal func doesNotOverclaimTheHundredBlock() {
        // The reason this is parsed as octets rather than matched as a "100."
        // prefix — most of 100.0.0.0/8 is ordinary public space.
        #expect(!GatewayURL.isPrivateHost("100.63.255.255"))
        #expect(!GatewayURL.isPrivateHost("100.128.0.1"))
        #expect(!GatewayURL.isPrivateHost("100.1.2.3"))
    }

    @Test("MagicDNS, mDNS, loopback, and RFC 1918 all count as private")
    internal func classifiesOtherPrivateHosts() {
        #expect(GatewayURL.isPrivateHost("my-box.tail1a2b3.ts.net"))
        #expect(GatewayURL.isPrivateHost("MY-BOX.TS.NET"))
        #expect(GatewayURL.isPrivateHost("mac-mini.local"))
        #expect(GatewayURL.isPrivateHost("localhost"))
        #expect(GatewayURL.isPrivateHost("127.0.0.1"))
        #expect(GatewayURL.isPrivateHost("10.0.0.5"))
        #expect(GatewayURL.isPrivateHost("192.168.1.9"))
        #expect(GatewayURL.isPrivateHost("172.16.0.1"))
        #expect(GatewayURL.isPrivateHost("172.31.255.255"))
        #expect(GatewayURL.isPrivateHost("::1"))
    }

    @Test("public hosts are not mistaken for private ones")
    internal func classifiesPublicHosts() {
        #expect(!GatewayURL.isPrivateHost("gateway.example.com"))
        #expect(!GatewayURL.isPrivateHost("8.8.8.8"))
        // Adjacent to 172.16/12 but outside it.
        #expect(!GatewayURL.isPrivateHost("172.15.0.1"))
        #expect(!GatewayURL.isPrivateHost("172.32.0.1"))
        // Looks like ts.net but isn't the tailnet zone.
        #expect(!GatewayURL.isPrivateHost("nots.net"))
    }

    // MARK: - HTTP origin (Standard / Centaur)

    @Test("an HTTP origin keeps host and port and drops the socket path")
    internal func buildsHTTPOrigin() throws {
        let bare = try #require(GatewayURL.httpOrigin("100.94.3.17:8080"))
        #expect(bare.absoluteString == "http://100.94.3.17:8080")

        let publicHost = try #require(GatewayURL.httpOrigin("dash.example.com"))
        #expect(publicHost.absoluteString == "https://dash.example.com")

        // A ws endpoint pasted into an HTTP field still names the right origin.
        let fromWS = try #require(GatewayURL.httpOrigin("ws://100.94.3.17:8642/v1/ws"))
        #expect(fromWS.absoluteString == "http://100.94.3.17:8642")

        // "/api/ws" is longer than "/v1/ws" — stripped by suffix, not by length.
        let fromSidecar = try #require(GatewayURL.httpOrigin("http://box.ts.net:8080/api/ws"))
        #expect(fromSidecar.absoluteString == "http://box.ts.net:8080")
    }

    // MARK: - What the settings layer derives from it

    /// Deliberately NOT written by instantiating `SettingsViewModel` and assigning
    /// `gatewayURL`. That property's `didSet` writes through to the real login
    /// Keychain, so such a test overwrites the developer's own saved harness URL
    /// and renames their active entry — and the `SecItem` calls stall the main
    /// actor for minutes waiting on an access prompt, blocking every other
    /// `@MainActor` test behind them.
    ///
    /// `buildWebSocketURL` and `needsCFAuth` are one-line delegations to
    /// `GatewayURL`, so exercising the pure functions covers the same logic. This
    /// asserts the *derivation* the settings layer performs — that CF Access is
    /// demanded from exactly the hosts that aren't private.
    @Test("Cloudflare Access is demanded of public hosts only")
    internal func cfAuthFollowsReachability() throws {
        for tailnet in ["100.94.3.17:8642", "my-box.tail1a2b3.ts.net:8642"] {
            let host = try #require(GatewayURL.normalize(tailnet)?.host)
            // needsCFAuth is `!isPrivateHost(host)`; a tailnet must not gate the
            // Connect button behind a cookie that is never coming.
            #expect(GatewayURL.isPrivateHost(host))
        }
        let publicHost = try #require(GatewayURL.normalize("wss://gateway.example.com/v1/ws")?.host)
        #expect(!GatewayURL.isPrivateHost(publicHost))
    }

    /// `SavedGateway` is a plain value type that touches no Keychain, so this one
    /// is safe to construct directly — unlike `SettingsViewModel` above.
    @Test("a Standard entry on a tailnet still yields a chat sidecar URL")
    internal func standardChatURLOnTailnet() throws {
        let entry = SavedGateway(
            name: "box",
            url: "100.94.3.17:8080",
            apiKey: "token123",
            kind: .hermesStandard
        )
        let url = try #require(entry.hermesStandardChatURL)
        #expect(url.scheme == "ws")
        #expect(url.host == "100.94.3.17")
        #expect(url.port == 8080)
        #expect(url.path == "/api/ws")
        #expect(url.query?.contains("token=token123") == true)
    }
}
