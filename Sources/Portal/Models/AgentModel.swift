import Foundation

/// A chat model selectable per session, routed to the gateway via
/// `config.set(key: "model", session_id:)`. Like `ResponseStyle`, the
/// selection lives in the session's runtime state so each session can run a
/// different model, and the last pick becomes the default for new sessions.
///
/// The static `catalog` below is the FALLBACK for gateways that predate the
/// `model.options` inventory RPC — when the live catalog loads, the picker
/// shows the gateway's real provider/model lists instead (see ModelCatalog).
/// `session.info` remains the source of truth for what the session is
/// actually running — an unknown reported model still renders (and shows as
/// checked) in the picker.
struct AgentModel: Identifiable, Equatable, Hashable, Codable {
    /// Wire ID sent to the gateway (e.g. "deepseek/deepseek-v4-pro").
    let id: String
    /// Human-readable label for menus ("DeepSeek v4 Pro").
    let label: String

    /// Models offered in the picker. Order is menu order.
    static let catalog: [AgentModel] = [
        AgentModel(id: "nousresearch/hermes-4-405b", label: "Hermes 4 405B"),
        AgentModel(id: "nousresearch/hermes-4-70b", label: "Hermes 4 70B"),
        AgentModel(id: "deepseek/deepseek-v4-pro", label: "DeepSeek v4 Pro"),
        AgentModel(id: "anthropic/claude-sonnet-5", label: "Claude Sonnet 5"),
        AgentModel(id: "z-ai/glm-5.1", label: "GLM 5.1"),
    ]

    /// The gateway may report models with a router prefix
    /// ("openrouter/deepseek/deepseek-v4-pro"); compare without it.
    static func normalize(_ modelID: String) -> String {
        modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "openrouter/", with: "")
            .lowercased()
    }

    /// Whether this catalog entry is the model a session reported running.
    func matches(sessionModel: String) -> Bool {
        Self.normalize(id) == Self.normalize(sessionModel)
    }

    /// Menu/badge label for an arbitrary wire ID: the catalog label when
    /// known, otherwise the ID with router/vendor prefixes stripped
    /// (the same compaction SessionExplorerView applies to node chips).
    static func displayName(for modelID: String) -> String {
        let normalized = normalize(modelID)
        if let known = catalog.first(where: { normalize($0.id) == normalized }) {
            return known.label
        }
        let stripped = modelID.replacingOccurrences(of: "openrouter/", with: "")
        return stripped.split(separator: "/").last.map(String.init) ?? stripped
    }

    // MARK: - Stored default

    static let userDefaultsKey = "defaultModelID"

    /// Model for new sessions — the last model the user picked anywhere.
    /// `nil` means the gateway's own default (no `config.set` is sent).
    static var storedDefaultID: String? {
        get {
            let value = UserDefaults.standard.string(forKey: userDefaultsKey)
            return (value?.isEmpty == false) ? value : nil
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: userDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: userDefaultsKey)
            }
        }
    }
}
