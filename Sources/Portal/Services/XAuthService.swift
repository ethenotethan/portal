import Foundation
import CryptoKit
import Combine
import os.log
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "XAuthService")

/// X (Twitter) sign-in via OAuth 2.0 PKCE — the browser flow that lets the
/// app read tweets with the user's own account (full tweet detail + comments,
/// no backend involvement). Public client: only a `client_id` is needed (no
/// secret ships in the app); tokens live in the Keychain.
///
/// Setup (one time): in the X Developer Portal, add the app's redirect URI
/// (`XAuthService.redirectURI`) to the app's callback list, and paste the
/// app's client ID into Settings → X. Then Connect opens X's authorize page
/// in the browser and the hermesnative:// callback lands the tokens.
@MainActor
internal final class XAuthService: ObservableObject {

    // MARK: - State

    /// The X app's client ID (public, PKCE). Persisted in UserDefaults — it
    /// identifies the app, it is not a secret.
    @Published internal var clientID: String {
        didSet { UserDefaults.standard.set(clientID, forKey: Self.clientIDDefaultsKey) }
    }
    /// True once tokens exist in the Keychain (signed in; may still need a
    /// refresh at call time — `validAccessToken()` handles that).
    @Published internal private(set) var isSignedIn = false
    /// A human-readable error from the last failed flow step (shown in Settings).
    @Published internal private(set) var lastError: String?

    /// The redirect URI to register in the X app's callback list.
    internal static let redirectURI = "hermesnative://x-oauth"
    private static let clientIDDefaultsKey = "x.oauth.clientID"
    private static let scopes = "tweet.read users.read offline.access"
    private static let authorizeEndpoint = "https://twitter.com/i/oauth2/authorize"
    private static let tokenEndpoint = "https://api.x.com/2/oauth2/token"

    /// PKCE material held only while a flow is in flight.
    private var pendingVerifier: String?
    private var pendingState: String?

    internal init() {
        clientID = UserDefaults.standard.string(forKey: Self.clientIDDefaultsKey) ?? ""
        isSignedIn = XKeychain.loadTokens() != nil
    }

    // MARK: - Sign in

    /// Open X's authorize page in the browser. Requires a client ID.
    internal func beginSignIn() {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            lastError = "Add your X app's client ID first (Settings → X)."
            return
        }
        let verifier = Self.makeVerifier()
        let state = Self.makeState()
        pendingVerifier = verifier
        pendingState = state

        var components = URLComponents(string: Self.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: Self.challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        guard let url = components?.url else { return }
        lastError = nil
        open(url)
    }

    /// Handle the hermesnative://x-oauth callback: validate state, exchange
    /// the code for tokens, store them.
    internal func handleCallback(code: String, state: String) async {
        guard state == pendingState, let verifier = pendingVerifier else {
            lastError = "Sign-in state mismatch — start the flow again."
            return
        }
        pendingVerifier = nil
        pendingState = nil
        do {
            let tokens = try await Self.tokenRequest(params: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
                "code_verifier": verifier,
            ])
            XKeychain.save(tokens)
            isSignedIn = true
            lastError = nil
        } catch {
            lastError = "Token exchange failed: \(error.localizedDescription)"
            log.error("X token exchange failed: \(error.localizedDescription)")
        }
    }

    internal func signOut() {
        XKeychain.deleteTokens()
        isSignedIn = false
    }

    // MARK: - Tokens

    /// A currently-valid access token, refreshing first when expired.
    internal func validAccessToken() async throws -> String {
        guard var tokens = XKeychain.loadTokens() else { throw XAuthError.notSignedIn }
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        // Refresh (offline.access was granted).
        do {
            let refreshed = try await Self.tokenRequest(params: [
                "grant_type": "refresh_token",
                "refresh_token": tokens.refreshToken,
                "client_id": clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            tokens = refreshed.mergingRefresh(from: tokens)
            XKeychain.save(tokens)
            return tokens.accessToken
        } catch {
            // The refresh token is dead — force a fresh sign-in.
            XKeychain.deleteTokens()
            isSignedIn = false
            throw XAuthError.refreshFailed(error.localizedDescription)
        }
    }

    // MARK: - Token endpoint

    /// The token endpoint returns {access_token, refresh_token?, expires_in,
    /// scope, token_type}. Errors surface as {error, error_description}.
    private static func tokenRequest(params: [String: String]) async throws -> XTokens {
        guard let endpoint = URL(string: tokenEndpoint) else { throw XAuthError.badResponse }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XAuthError.badResponse }
        let obj: [String: Any]?
        do {
            obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            obj = nil
        }
        guard (200..<300).contains(http.statusCode) else {
            let description = (obj?["error_description"] as? String)
                ?? (obj?["error"] as? String) ?? "HTTP \(http.statusCode)"
            throw XAuthError.endpointRejected(description)
        }
        guard let access = obj?["access_token"] as? String else {
            throw XAuthError.badResponse
        }
        let expiresIn = (obj?["expires_in"] as? NSNumber)?.doubleValue ?? 7200
        return XTokens(
            accessToken: access,
            refreshToken: (obj?["refresh_token"] as? String) ?? "",
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - PKCE primitives

    /// RFC 7636: BASE64URL-NOPAD(SHA256(verifier)).
    nonisolated internal static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated internal static func makeVerifier() -> String {
        Self.randomString(length: 64, characters: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    }

    nonisolated internal static func makeState() -> String {
        Self.randomString(length: 24, characters: "abcdefghijklmnopqrstuvwxyz0123456789")
    }

    nonisolated private static func randomString(length: Int, characters: String) -> String {
        let chars = Array(characters)
        return String((0..<length).map { _ in
            chars[chars.index(chars.startIndex, offsetBy: Int.random(in: 0..<chars.count))]
        })
    }

    private func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Token model + Keychain

internal enum XAuthError: LocalizedError {
    case notSignedIn
    case refreshFailed(String)
    case endpointRejected(String)
    case badResponse

    internal var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Not signed in to X"
        case .refreshFailed(let detail): return "X sign-in expired: \(detail)"
        case .endpointRejected(let detail): return detail
        case .badResponse: return "Bad response from X"
        }
    }
}

/// The stored OAuth tokens. Keychain-persisted as JSON.
internal struct XTokens: Codable, Equatable {
    internal let accessToken: String
    internal let refreshToken: String
    internal let expiresAt: Date

    /// A refreshed response may omit refresh_token — keep the old one.
    internal func mergingRefresh(from old: XTokens) -> XTokens {
        XTokens(
            accessToken: accessToken,
            refreshToken: refreshToken.isEmpty ? old.refreshToken : refreshToken,
            expiresAt: expiresAt
        )
    }
}

/// Minimal Keychain wrapper for the X tokens (generic-password item, same
/// pattern as KeychainStore but scoped to the X OAuth material).
internal enum XKeychain {
    private static let service = "com.ethenotethan.Portal.x-oauth"
    private static let account = "tokens"

    internal static func save(_ tokens: XTokens) {
        deleteTokens()
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            log.error("XKeychain: failed to encode tokens: \(error.localizedDescription)")
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    internal static func loadTokens() -> XTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        do {
            return try JSONDecoder().decode(XTokens.self, from: data)
        } catch {
            log.error("XKeychain: failed to decode tokens: \(error.localizedDescription)")
            return nil
        }
    }

    internal static func deleteTokens() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
