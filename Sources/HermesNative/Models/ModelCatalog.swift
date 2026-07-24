import Foundation

/// Decoded `model.options` RPC payload: the gateway's live model inventory,
/// grouped by provider. This is the same substrate the TUI's model picker
/// dialog renders — curated agentic model lists per provider (no TTS or
/// embedding models), with authentication state per row.
///
/// The static `AgentModel.catalog` remains the fallback for gateways that
/// predate the RPC; `ModelPickerMenu` prefers this catalog whenever a fetch
/// has succeeded.
struct ModelCatalog: Equatable {
    struct Provider: Equatable, Identifiable {
        /// Stable slug ("nous", "openrouter", "deepseek").
        let slug: String
        /// Display label ("Nous", "OpenRouter").
        let name: String
        /// Wire IDs in the provider's curated order.
        let models: [String]
        /// Whether credentials exist for this provider. Unauthenticated
        /// providers are listed by the RPC (include_unconfigured) but the
        /// picker only offers models from authenticated ones.
        let authenticated: Bool
        /// True when this provider serves the session's current model.
        let isCurrent: Bool

        var id: String { slug }
    }

    let providers: [Provider]
    /// Wire ID of the model the gateway reports as current.
    let currentModel: String
    /// Slug of the provider serving `currentModel`.
    let currentProvider: String

    /// Providers worth showing: authenticated and non-empty.
    var selectableProviders: [Provider] {
        providers.filter { $0.authenticated && !$0.models.isEmpty }
    }

    /// Every selectable wire ID, for membership checks.
    var allModelIDs: Set<String> {
        Set(selectableProviders.flatMap(\.models))
    }

    /// Decode from the RPC result dictionary. Returns nil when the payload
    /// has no usable providers array (old gateway, partial failure).
    static func from(_ result: [String: AnyCodable]) -> ModelCatalog? {
        guard let rows = result["providers"]?.arrayValue else { return nil }
        let providers = rows.compactMap { row -> Provider? in
            guard let d = row.dictionaryValue,
                  let slug = d["slug"]?.stringValue, !slug.isEmpty else { return nil }
            let models = d["models"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return Provider(
                slug: slug,
                name: d["name"]?.stringValue ?? slug,
                models: models,
                // Rows from list_authenticated_providers predate picker_hints;
                // absent flag means the row was emitted because it IS authed.
                authenticated: d["authenticated"]?.boolValue ?? true,
                isCurrent: d["is_current"]?.boolValue ?? false
            )
        }
        guard !providers.isEmpty else { return nil }
        return ModelCatalog(
            providers: providers,
            currentModel: result["model"]?.stringValue ?? "",
            currentProvider: result["provider"]?.stringValue ?? ""
        )
    }

    /// Menu label for a wire ID: the static catalog's friendly label when
    /// known, otherwise the compacted ID (same rule as the badge).
    static func displayName(for modelID: String) -> String {
        AgentModel.displayName(for: modelID)
    }
}

/// A pending expensive-model gate awaiting the user's decision.
struct ModelSwitchConfirmation: Equatable, Identifiable {
    let model: String
    let message: String
    /// Provider slug the pick came from (nil = current provider) — the
    /// confirmed retry must route the same way the original pick did.
    var provider: String?

    var id: String { model }
}

/// Outcome of a model switch the UI must surface: the gateway can veto with
/// a confirmation gate (expensive model) or attach a warning while accepting.
struct ModelSwitchOutcome: Equatable {
    /// Wire ID the gateway settled on (may be normalized/expanded).
    let value: String
    /// Non-fatal advisory ("pricing unknown", tier notes). Empty = none.
    let warning: String
    /// True when the switch did NOT apply and needs explicit confirmation
    /// (resend config.set with confirm_expensive_model: true).
    let confirmRequired: Bool
    /// Human-readable question to show when confirmRequired.
    let confirmMessage: String

    static func from(_ result: [String: AnyCodable]?) -> ModelSwitchOutcome {
        let d = result ?? [:]
        return ModelSwitchOutcome(
            value: d["value"]?.stringValue ?? "",
            warning: d["warning"]?.stringValue ?? "",
            confirmRequired: d["confirm_required"]?.boolValue ?? false,
            confirmMessage: d["confirm_message"]?.stringValue ?? ""
        )
    }
}
