import Foundation

/// A saved harness connection the user can switch between.
///
/// Stored as a JSON list in the Keychain (see `KeychainStore.saveGateways`).
/// The active entry's `url`/`apiKey` are mirrored into
/// `SettingsViewModel.gatewayURL`/`apiKey` so the app-level WebSocket connect
/// path keeps working unchanged.
struct SavedGateway: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var apiKey: String
    /// Absolute path to a user-uploaded avatar image for this harness's persona.
    /// `nil` → the persona falls back to a deterministic identicon generated from
    /// `id`. The harness name doubles as the persona name (see `PersonaManager`),
    /// so this is the persona's picture. Stored as a path (not image bytes)
    /// because `SavedGateway` lives in the Keychain — see `PersonaImage`.
    internal var avatarImagePath: String?

    /// The backend `kind` this entry was saved with, from builds that spoke to
    /// more than one agent platform. Portal now speaks only to the harness, so
    /// an entry saved for a retired platform is dropped at load rather than
    /// dialed as a harness (see `speaksHarness`). Decode-only: never re-encoded.
    private let legacyKind: String?

    internal init(
        id: UUID = UUID(),
        name: String,
        url: String,
        apiKey: String,
        avatarImagePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
        self.avatarImagePath = avatarImagePath
        self.legacyKind = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, apiKey, kind, avatarImagePath
    }

    // Custom decode: entries persisted before `avatarImagePath` existed decode
    // with no avatar (identicon fallback); `kind` is read only to recognize
    // entries from retired platforms.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        self.apiKey = try c.decode(String.self, forKey: .apiKey)
        self.avatarImagePath = try c.decodeIfPresent(String.self, forKey: .avatarImagePath)
        self.legacyKind = try c.decodeIfPresent(String.self, forKey: .kind)
    }

    internal func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(url, forKey: .url)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encodeIfPresent(avatarImagePath, forKey: .avatarImagePath)
    }

    /// False for an entry saved as a backend Portal no longer speaks — the
    /// retired Centaur and Hermes Standard kinds. Entries with no recorded kind
    /// predate the field and were always harness connections.
    internal var speaksHarness: Bool {
        legacyKind == nil || legacyKind == "hermes"
    }

    /// A short label for display when `name` is empty — falls back to the host.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: url)?.host { return host }
        return url
    }
}
