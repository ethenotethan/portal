import Foundation

// MARK: - Inventory sections of a hermes.architecture document

/// One architectural component: the files and declarations it owns.
internal struct ArchitectureComponentRecord: Hashable, Identifiable {
    internal let id: String
    internal let label: String
    internal let layer: String
    internal let description: String
    internal let external: Bool
    internal let fileCount: Int
    internal let lineCount: Int
    internal let declarationCount: Int
    internal let files: [String]
    internal let declarations: [String]

    internal static func decode(_ value: AnyCodable) -> ArchitectureComponentRecord? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureComponentRecord(
            id: id,
            label: d["label"]?.stringValue ?? id,
            layer: d["layer"]?.stringValue ?? "",
            description: d["description"]?.stringValue ?? "",
            external: d["external"]?.boolValue ?? false,
            fileCount: d["file_count"]?.intValue ?? 0,
            lineCount: d["line_count"]?.intValue ?? 0,
            declarationCount: d["declaration_count"]?.intValue ?? 0,
            files: (d["files"]?.arrayValue ?? []).compactMap(\.stringValue),
            declarations: (d["declarations"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
    }
}

/// One architectural layer, in the order the model draws them.
internal struct ArchitectureLayerRecord: Hashable, Identifiable {
    internal let id: String
    internal let label: String
    internal let order: Int

    internal static func decode(_ value: AnyCodable) -> ArchitectureLayerRecord? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureLayerRecord(id: id, label: d["label"]?.stringValue ?? id, order: d["order"]?.intValue ?? 0)
    }
}

/// One interplay invariant and whether it held at this revision.
internal struct ArchitectureInvariantRecord: Hashable, Identifiable {
    internal let id: String
    internal let kind: String
    internal let status: String
    internal let why: String
    internal let checked: Int

    internal var holds: Bool { status == "holds" }

    internal static func decode(_ value: AnyCodable) -> ArchitectureInvariantRecord? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureInvariantRecord(
            id: id,
            kind: d["kind"]?.stringValue ?? "",
            status: d["status"]?.stringValue ?? "unchecked",
            why: d["why"]?.stringValue ?? "",
            checked: d["checked"]?.intValue ?? 0
        )
    }
}

/// A `path:line` the model cites for a record.
internal struct ArchitectureEvidenceRef: Hashable {
    internal let path: String
    internal let line: Int

    internal var location: String { line > 0 ? "\(path):\(line)" : path }

    internal static func decode(_ value: AnyCodable?) -> ArchitectureEvidenceRef? {
        guard let d = value?.dictionaryValue, let path = d["path"]?.stringValue, !path.isEmpty else { return nil }
        return ArchitectureEvidenceRef(path: path, line: d["line"]?.intValue ?? 0)
    }
}

/// One data store: the type the extractor recognised, how it persists, and
/// the artifacts (files, folders, defaults keys) it names.
internal struct ArchitectureStoreRecord: Hashable, Identifiable {
    internal struct Artifact: Hashable {
        internal let kind: String
        internal let label: String
    }

    internal let id: String
    internal let label: String
    internal let kind: String
    internal let component: String?
    internal let persistence: [String]
    internal let mechanisms: [String]
    internal let artifacts: [Artifact]
    internal let evidence: ArchitectureEvidenceRef?

    /// The mechanism a store is grouped under: its first persistence kind, or `unobserved`.
    internal var primaryPersistence: String { persistence.first ?? "unobserved" }

    internal static func decode(_ value: AnyCodable) -> ArchitectureStoreRecord? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        let mechanisms = (d["mechanisms"]?.arrayValue ?? []).compactMap { $0.dictionaryValue?["label"]?.stringValue }
        let artifacts = (d["artifacts"]?.arrayValue ?? []).compactMap { item -> Artifact? in
            guard let a = item.dictionaryValue, let label = a["label"]?.stringValue else { return nil }
            return Artifact(kind: a["kind"]?.stringValue ?? "", label: label)
        }
        return ArchitectureStoreRecord(
            id: id,
            label: d["label"]?.stringValue ?? d["type_name"]?.stringValue ?? id,
            kind: d["kind"]?.stringValue ?? "",
            component: d["component"]?.stringValue,
            persistence: (d["persistence"]?.arrayValue ?? []).compactMap(\.stringValue),
            mechanisms: mechanisms,
            artifacts: artifacts,
            evidence: ArchitectureEvidenceRef.decode(d["evidence"])
        )
    }
}

/// One external system the code reaches, as configured and as observed.
internal struct ArchitectureExternalRecord: Hashable, Identifiable {
    internal let id: String
    internal let label: String
    internal let category: String
    internal let description: String
    internal let component: String?
    internal let protocolName: String
    internal let hitCount: Int
    internal let fileCount: Int

    internal static func decode(_ value: AnyCodable) -> ArchitectureExternalRecord? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureExternalRecord(
            id: id,
            label: d["label"]?.stringValue ?? id,
            category: d["category"]?.stringValue ?? "",
            description: d["description"]?.stringValue ?? "",
            component: d["component"]?.stringValue,
            protocolName: d["protocol"]?.stringValue ?? "",
            hitCount: d["hit_count"]?.intValue ?? 0,
            fileCount: d["file_count"]?.intValue ?? 0
        )
    }
}

/// The inventory of a document: components by layer, the invariants, and the
/// optional stores and externals sections. Decoded tolerantly: a section the
/// document lacks is empty, never an error, so the view can say so.
internal struct ArchitectureInventoryDocument: Hashable {
    internal let layers: [ArchitectureLayerRecord]
    internal let components: [ArchitectureComponentRecord]
    internal let invariants: [ArchitectureInvariantRecord]
    internal let stores: [ArchitectureStoreRecord]
    internal let externals: [ArchitectureExternalRecord]
    internal let hasStoresSection: Bool
    internal let hasExternalsSection: Bool

    internal static let empty = ArchitectureInventoryDocument(
        layers: [], components: [], invariants: [], stores: [], externals: [], hasStoresSection: false, hasExternalsSection: false
    )

    internal static func decode(_ document: ArchitectureModelDocument) -> ArchitectureInventoryDocument {
        decode(model: document.model)
    }

    internal static func decode(model: AnyCodable) -> ArchitectureInventoryDocument {
        guard let d = model.dictionaryValue else { return .empty }
        let layers = (d["layers"]?.arrayValue ?? []).compactMap(ArchitectureLayerRecord.decode).sorted { $0.order < $1.order }
        let components = (d["components"]?.arrayValue ?? []).compactMap(ArchitectureComponentRecord.decode)
        let invariants = (d["interplay"]?.dictionaryValue?["invariants"]?.arrayValue ?? []).compactMap(ArchitectureInvariantRecord.decode)
        let storesSection = d["stores"]?.dictionaryValue
        let externalsSection = d["externals"]?.dictionaryValue
        let stores = (storesSection?["items"]?.arrayValue ?? []).compactMap(ArchitectureStoreRecord.decode)
        let externals = (externalsSection?["systems"]?.arrayValue ?? []).compactMap(ArchitectureExternalRecord.decode)
        return ArchitectureInventoryDocument(
            layers: layers,
            components: components,
            invariants: invariants,
            stores: stores,
            externals: externals,
            hasStoresSection: storesSection != nil,
            hasExternalsSection: externalsSection != nil
        )
    }

    /// The layer label for a component, falling back to the raw layer id.
    internal func layerLabel(_ layerID: String) -> String {
        layers.first { $0.id == layerID }?.label ?? (layerID.isEmpty ? "Unlayered" : layerID)
    }
}
