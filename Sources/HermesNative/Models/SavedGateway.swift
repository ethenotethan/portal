import Foundation

/// Which agent platform a saved backend entry speaks.
enum BackendKind: String, Codable, CaseIterable, Sendable {
    /// Hermes gateway — WebSocket JSON-RPC, full feature surface. The app's
    /// "home" backend: session list, wiki, skills, cron all live here.
    case hermes
    /// Centaur control plane — REST + SSE, chat-only surface.
    case centaur

    var displayName: String {
        switch self {
        case .hermes: return "Hermes"
        case .centaur: return "Centaur"
        }
    }
}

/// A saved agent backend the user can switch between.
///
/// Stored as a JSON list in the Keychain (see `KeychainStore.saveGateways`).
/// Hermes entries: the active one's `url`/`apiKey` are mirrored into
/// `SettingsViewModel.gatewayURL`/`apiKey` so the app-level WebSocket connect
/// path keeps working unchanged. Centaur entries are never "active" at the
/// app level — they are per-session targets offered at session create.
struct SavedGateway: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var apiKey: String
    var kind: BackendKind

    init(id: UUID = UUID(), name: String, url: String, apiKey: String, kind: BackendKind = .hermes) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
        self.kind = kind
    }

    // Custom decode: entries persisted before `kind` existed are hermes.
    private enum CodingKeys: String, CodingKey {
        case id, name, url, apiKey, kind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        self.apiKey = try c.decode(String.self, forKey: .apiKey)
        self.kind = try c.decodeIfPresent(BackendKind.self, forKey: .kind) ?? .hermes
    }

    /// A short label for display when `name` is empty — falls back to the host.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: url)?.host { return host }
        return url
    }
}
