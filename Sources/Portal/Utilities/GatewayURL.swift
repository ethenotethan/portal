import Foundation

/// Turns what a user actually types into a harness address into a usable
/// WebSocket URL, and decides whether that address is on a private network.
///
/// Both halves exist because of Tailscale. A tailnet address is typed as a bare
/// `host:port` — `100.94.3.17:8642`, or a MagicDNS name like
/// `my-box.tail1a2b3.ts.net:8642` — and `URL(string:)` handles neither the way a
/// reader expects:
///
/// - `100.94.3.17:8642/v1/ws` parses as **nil**. The connect path then logs
///   "Invalid gateway URL" and leaves the previously-built client in place,
///   which on a cold launch is the loopback default. The app looks like it
///   silently rewrote the tailnet address to localhost.
/// - `my-box.tail1a2b3.ts.net:8642/v1/ws` is worse: it parses *successfully*
///   with `scheme == "my-box.tail1a2b3.ts.net"` and a **nil host**, because
///   `URL` sees `scheme:opaque`. Nothing reports an error; the socket just never
///   opens.
///
/// So a scheme is inferred rather than required, and the address is parsed with
/// `URLComponents` (which keeps host, port, and query separate) instead of
/// string surgery.
internal enum GatewayURL {
    /// Paths that already name a WebSocket endpoint, so normalization leaves
    /// them alone. `/api/ws` is the Hermes Standard dashboard's chat sidecar.
    private static let wsPaths = ["/v1/ws", "/api/ws"]

    /// The WebSocket URL for a typed harness address, or nil when there is no
    /// host to dial or the scheme isn't one we speak.
    ///
    /// Returning nil is meaningful: callers must surface it rather than fall
    /// back to a default, because a default here is how a tailnet address turns
    /// into localhost.
    internal static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let schemed = applyingScheme(to: trimmed) else { return nil }
        guard var comps = URLComponents(string: schemed),
              let host = comps.host, !host.isEmpty else { return nil }

        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        if !wsPaths.contains(where: path.hasSuffix) {
            path += Constants.wsPath
        }
        comps.path = path
        return comps.url
    }

    /// The HTTP(S) base URL for a typed harness address, for the backends that
    /// speak REST rather than WebSocket (Hermes Standard, Centaur).
    ///
    /// Same inference as `normalize`, minus the `/v1/ws` path: these callers were
    /// handing a raw `URL(string:)` result to clients that require a non-nil host
    /// and an http/https scheme, so a bare `100.94.3.17:8080` produced a nil
    /// client and the feature just showed up empty.
    internal static func httpOrigin(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let schemed = applyingScheme(to: trimmed),
              var comps = URLComponents(string: schemed),
              let host = comps.host, !host.isEmpty else { return nil }
        // applyingScheme normalizes to ws/wss; these callers want http/https.
        comps.scheme = comps.scheme == "wss" ? "https" : "http"
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        // A ws endpoint pasted into an HTTP-backend field is still naming the
        // same origin — keep the host, drop the socket path. Matched per-suffix
        // because the two differ in length ("/v1/ws" vs "/api/ws").
        if let wsPath = wsPaths.first(where: path.hasSuffix) {
            path = String(path.dropLast(wsPath.count))
        }
        comps.path = path
        return comps.url
    }

    /// Whether this host is reachable only from a private network — a tailnet,
    /// a LAN, or the machine itself.
    ///
    /// Drives two decisions: which scheme a scheme-less address gets, and
    /// whether to demand Cloudflare Access. Getting Tailscale wrong here is not
    /// cosmetic — `needsCFAuth` *disables the Connect button* until a CF cookie
    /// exists, so a tailnet address was unusable in onboarding: there is no
    /// Cloudflare in front of a tailnet, and no cookie was ever coming.
    internal static func isPrivateHost(_ host: String) -> Bool {
        let name = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if name == "localhost" || name == "::1" || name.hasSuffix(".localhost") {
            return true
        }
        // Tailscale MagicDNS. `ts.net` is the tailnet's own DNS zone, so it is
        // never publicly routable even though it looks like an ordinary domain.
        if name.hasSuffix(".ts.net") { return true }
        // Bonjour/mDNS — a `.local` name resolves on the LAN only.
        if name.hasSuffix(".local") { return true }
        // IPv6 loopback/link-local/unique-local.
        if name.hasPrefix("fe80:") || name.hasPrefix("fc") || name.hasPrefix("fd") {
            return true
        }
        return isPrivateIPv4(name)
    }

    /// RFC 1918, loopback, IPv4 link-local, and — the point of this whole file —
    /// the RFC 6598 CGNAT block `100.64.0.0/10` that Tailscale assigns from.
    ///
    /// Parsed as octets rather than matched as a string prefix: `hasPrefix("10.")`
    /// happens to be right, but the CGNAT range cannot be expressed that way at
    /// all (`100.64.` … `100.127.` is 64 distinct prefixes), and a naive
    /// `hasPrefix("100.")` would wrongly claim all of `100.0.0.0/8`.
    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }

        switch (octets[0], octets[1]) {
        case (10, _), (127, _):
            return true
        case (192, 168):
            return true
        case (169, 254):
            return true
        case (172, 16...31):
            return true
        case (100, 64...127):
            // Tailscale's CGNAT range.
            return true
        default:
            return false
        }
    }

    /// Prefix the address with a scheme when it has none, or canonicalize the
    /// one it has to `ws`/`wss`. Returns nil for a scheme we can't dial.
    ///
    /// A scheme is detected by `://` and nothing else. Looking for a colon is
    /// what makes `host:8642` read as a scheme — the port then vanishes into an
    /// opaque URL with no host at all.
    private static func applyingScheme(to text: String) -> String? {
        guard let marker = text.range(of: "://") else {
            // No scheme: assume TLS on the public internet, and plaintext on a
            // private network. A tailnet is already encrypted end-to-end and the
            // harness listens on plain HTTP there, so demanding `wss://` would
            // reject the address a Tailscale user is most likely to type.
            let scheme = isPrivateHost(hostFragment(of: text)) ? "ws" : "wss"
            return "\(scheme)://\(text)"
        }
        let rest = String(text[marker.upperBound...])
        switch text[text.startIndex..<marker.lowerBound].lowercased() {
        case "ws", "http": return "ws://\(rest)"
        case "wss", "https": return "wss://\(rest)"
        default: return nil
        }
    }

    /// The host inside a scheme-less address, so privacy can be judged before a
    /// scheme (and therefore a parseable URL) exists. Strips any path, userinfo,
    /// and port, and unwraps a bracketed IPv6 literal.
    private static func hostFragment(of text: String) -> String {
        var authority = text
        if let slash = authority.firstIndex(of: "/") {
            authority = String(authority[authority.startIndex..<slash])
        }
        if let at = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: at)...])
        }
        if authority.hasPrefix("[") {
            // IPv6 literal: the colons inside the brackets are not a port.
            if let close = authority.firstIndex(of: "]") {
                return String(authority[authority.index(after: authority.startIndex)..<close])
            }
            return authority
        }
        if let colon = authority.lastIndex(of: ":") {
            authority = String(authority[authority.startIndex..<colon])
        }
        return authority
    }
}
