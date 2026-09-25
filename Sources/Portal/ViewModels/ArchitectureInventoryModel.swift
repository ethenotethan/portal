import Foundation

/// The inventory tab's state: the decoded inventory, a search that narrows
/// every section, and the selected component. Pure grouping and sorting live
/// here so the view stays declarative and the logic is unit-testable.
internal struct ArchitectureInventoryModel: Hashable {
    /// Components under one layer, in the model's layer order.
    internal struct LayerGroup: Hashable, Identifiable {
        internal let id: String
        internal let label: String
        internal let components: [ArchitectureComponentRecord]

        internal var fileCount: Int { components.reduce(0) { $0 + $1.fileCount } }
        internal var lineCount: Int { components.reduce(0) { $0 + $1.lineCount } }
    }

    /// Stores under one persistence mechanism, or externals under one category.
    internal struct Group<Item: Hashable & Identifiable>: Hashable, Identifiable {
        internal let id: String
        internal let label: String
        internal let items: [Item]
    }

    internal let inventory: ArchitectureInventoryDocument
    internal var query = ""
    internal var selectedComponentID: String?

    internal init(inventory: ArchitectureInventoryDocument, query: String = "", selectedComponentID: String? = nil) {
        self.inventory = inventory
        self.query = query
        self.selectedComponentID = selectedComponentID
    }

    private var needle: String { query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    private func matches(_ haystack: [String]) -> Bool {
        needle.isEmpty || haystack.contains { $0.lowercased().contains(needle) }
    }

    // MARK: Components

    /// Components matching the search, sorted by label within each layer; a
    /// component also matches when one of its files or declarations does.
    internal var layerGroups: [LayerGroup] {
        let matching = inventory.components.filter { component in
            !component.external && matches([component.id, component.label, component.description] + component.files + component.declarations)
        }
        let known = inventory.layers.map(\.id)
        let order = { (layer: String) -> Int in known.firstIndex(of: layer) ?? known.count }
        let layerIDs = Array(Set(matching.map(\.layer))).sorted { order($0) < order($1) || (order($0) == order($1) && $0 < $1) }
        return layerIDs.map { layerID in
            LayerGroup(
                id: layerID,
                label: inventory.layerLabel(layerID),
                components: matching.filter { $0.layer == layerID }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            )
        }
    }

    internal var selectedComponent: ArchitectureComponentRecord? {
        guard let selectedComponentID else { return nil }
        return inventory.components.first { $0.id == selectedComponentID }
    }

    /// The selected component's files, narrowed by the search when it is set.
    internal var selectedFiles: [String] {
        guard let component = selectedComponent else { return [] }
        let hits = component.files.filter { $0.lowercased().contains(needle) }
        return needle.isEmpty || hits.isEmpty ? component.files : hits
    }

    internal var selectedDeclarations: [String] {
        guard let component = selectedComponent else { return [] }
        let hits = component.declarations.filter { $0.lowercased().contains(needle) }
        return needle.isEmpty || hits.isEmpty ? component.declarations : hits
    }

    // MARK: Invariants

    internal var invariants: [ArchitectureInvariantRecord] {
        inventory.invariants.filter { matches([$0.id, $0.kind, $0.why, $0.status]) }
    }

    internal var invariantsHolding: Int { inventory.invariants.filter(\.holds).count }

    // MARK: Stores

    /// Stores grouped by their primary persistence mechanism, file-backed first.
    internal var storeGroups: [Group<ArchitectureStoreRecord>] {
        let matching = inventory.stores.filter { store in
            matches([store.id, store.label, store.kind, store.component ?? ""] + store.persistence + store.artifacts.map(\.label))
        }
        let order = ["file", "defaults", "keychain", "unobserved"]
        let keys = Array(Set(matching.map(\.primaryPersistence))).sorted {
            (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1)
        }
        return keys.map { key in
            Group(
                id: key,
                label: Self.persistenceLabel(key),
                items: matching.filter { $0.primaryPersistence == key }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            )
        }
    }

    internal static func persistenceLabel(_ key: String) -> String {
        switch key {
        case "file": return "File system"
        case "defaults": return "UserDefaults"
        case "keychain": return "Keychain"
        case "unobserved": return "In memory or delegated (unobserved)"
        default: return key
        }
    }

    // MARK: Externals

    /// External systems grouped by category, categories alphabetical.
    internal var externalGroups: [Group<ArchitectureExternalRecord>] {
        let matching = inventory.externals.filter { external in
            matches([external.id, external.label, external.category, external.description, external.protocolName, external.component ?? ""])
        }
        let keys = Array(Set(matching.map(\.category))).sorted()
        return keys.map { key in
            Group(
                id: key,
                label: key.isEmpty ? "Uncategorised" : key.prefix(1).uppercased() + key.dropFirst(),
                items: matching.filter { $0.category == key }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            )
        }
    }

    // MARK: Counts for the header

    internal var componentCount: Int { inventory.components.filter { !$0.external }.count }
    internal var totalFiles: Int { inventory.components.filter { !$0.external }.reduce(0) { $0 + $1.fileCount } }
    internal var totalLines: Int { inventory.components.filter { !$0.external }.reduce(0) { $0 + $1.lineCount } }
}
