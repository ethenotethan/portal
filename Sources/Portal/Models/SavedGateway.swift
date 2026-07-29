import Foundation

/// Top-level Portal surfaces a backend can honestly serve.
enum BackendNavigationCapability: String, Codable, CaseIterable, Sendable {
    case chat
    case sessions
    case cron
    case notifications
    case skills
    case settings
    case wiki
    case artifacts
}

/// Which agent platform a saved backend entry speaks.
enum BackendKind: String, Codable, CaseIterable, Sendable {
    /// Hermes gateway — WebSocket JSON-RPC, full feature surface. The app's
    /// "home" backend: session list, wiki, skills, cron all live here.
    case hermes
    /// Upstream/default Hermes dashboard — authenticated HTTP management API
    /// plus an optional advertised SSE notification stream.
    case hermesStandard
    /// Centaur control plane — REST + SSE, chat-only surface.
    case centaur

    var displayName: String {
        switch self {
        case .hermes: return "Hermes Gateway"
        case .hermesStandard: return "Hermes Standard"
        case .centaur: return "Centaur"
        }
    }

    /// Session-scoped backends host individual sessions (picked at session
    /// create) and can never be the app-level active gateway. Views branch on
    /// this — never on concrete kinds — so new platforms only touch this file.
    var isSessionScoped: Bool {
        switch self {
        case .hermes, .hermesStandard: return false
        case .centaur: return true
        }
    }

    /// Management-scoped backends are selectable without replacing the
    /// app-level Hermes Gateway WebSocket.
    var isManagementScoped: Bool { self == .hermesStandard }

    /// A focused backend is either session-scoped or management-scoped.
    var isFocusScoped: Bool { isSessionScoped || isManagementScoped }

    var navigationCapabilities: [BackendNavigationCapability] {
        switch self {
        case .hermes:
            return BackendNavigationCapability.allCases
        case .hermesStandard:
            return [.sessions, .cron, .notifications, .skills, .settings]
        case .centaur:
            return [.chat, .sessions]
        }
    }

    /// SF Symbol for menu/list rows.
    var iconName: String {
        switch self {
        case .hermes: return "server.rack"
        case .hermesStandard: return "server.rack"
        case .centaur: return "shippingbox"
        }
    }

    // MARK: - Field labels (Add/Edit sheet)

    var urlFieldLabel: String {
        switch self {
        case .hermes: return "Hermes Gateway URL"
        case .hermesStandard: return "Hermes Standard URL (https://…)"
        case .centaur: return "Centaur URL (https://…)"
        }
    }

    var keyFieldLabel: String {
        switch self {
        case .hermes: return "API Key"
        case .hermesStandard: return "Dashboard session token"
        case .centaur: return "API key / console JWT"
        }
    }

    /// Footnote shown in the Add/Edit sheet for session-scoped kinds.
    var sessionScopedFootnote: String? {
        switch self {
        case .hermes:
            return nil
        case .hermesStandard:
            return "Hermes Standard is management-only: Sessions, Cron, Notifications, Skills, and Settings."
        case .centaur:
            return "Centaur backends host individual sessions (chosen from the New Session menu). "
                + "Wiki, skills, attachments, and interactive prompts are unavailable on Centaur sessions."
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
    /// Absolute path to a user-uploaded avatar image for this gateway's persona.
    /// `nil` → the persona falls back to a deterministic identicon generated from
    /// `id`. The gateway name doubles as the persona name (see `PersonaManager`),
    /// so this is the persona's picture. Stored as a path (not image bytes)
    /// because `SavedGateway` lives in the Keychain — see `PersonaImage`.
    internal var avatarImagePath: String?

    internal init(
        id: UUID = UUID(),
        name: String,
        url: String,
        apiKey: String,
        kind: BackendKind = .hermes,
        avatarImagePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
        self.kind = kind
        self.avatarImagePath = avatarImagePath
    }

    // Custom decode: entries persisted before `kind`/`avatarImagePath` existed
    // decode as hermes with no avatar (identicon fallback).
    private enum CodingKeys: String, CodingKey {
        case id, name, url, apiKey, kind, avatarImagePath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.url = try c.decode(String.self, forKey: .url)
        self.apiKey = try c.decode(String.self, forKey: .apiKey)
        self.kind = try c.decodeIfPresent(BackendKind.self, forKey: .kind) ?? .hermes
        self.avatarImagePath = try c.decodeIfPresent(String.self, forKey: .avatarImagePath)
    }

    /// A short label for display when `name` is empty — falls back to the host.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: url)?.host { return host }
        return url
    }
}
