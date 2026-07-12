import Foundation

/// Remembers which saved backend entry each session was created on, so
/// selecting a session can route the chat pipeline to the right client.
///
/// Sessions with no recorded entry are Hermes sessions (the overwhelmingly
/// common case, and everything that predates multi-backend). Persisted in
/// UserDefaults: the map is tiny (session ID → UUID string) and not secret —
/// credentials stay in the Keychain with the backend entries themselves.
@MainActor
final class SessionBackendRegistry {

    static let shared = SessionBackendRegistry()

    private static let storageKey = "hermes.sessionBackends"

    private var backendBySession: [String: UUID]

    private init() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        backendBySession = raw.compactMapValues(UUID.init(uuidString:))
    }

    /// Record that a session lives on the given backend entry.
    func bind(sessionID: String, backendID: UUID) {
        backendBySession[sessionID] = backendID
        persist()
    }

    /// The backend entry ID for a session; nil = Hermes home gateway.
    func backendID(for sessionID: String) -> UUID? {
        backendBySession[sessionID]
    }

    func forget(sessionID: String) {
        guard backendBySession.removeValue(forKey: sessionID) != nil else { return }
        persist()
    }

    private func persist() {
        let raw = backendBySession.mapValues(\.uuidString)
        UserDefaults.standard.set(raw, forKey: Self.storageKey)
    }
}
