import Foundation

/// A saved Hermes agent gateway the user can switch between.
///
/// Stored as a JSON list in the Keychain (see `KeychainStore.saveGateways`).
/// The currently-active gateway's `url`/`apiKey` are mirrored into
/// `SettingsViewModel.gatewayURL`/`apiKey` so the existing connect path
/// (which reads those fields) keeps working unchanged.
struct SavedGateway: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var apiKey: String

    init(id: UUID = UUID(), name: String, url: String, apiKey: String) {
        self.id = id
        self.name = name
        self.url = url
        self.apiKey = apiKey
    }

    /// A short label for display when `name` is empty — falls back to the host.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if let host = URL(string: url)?.host { return host }
        return url
    }
}
