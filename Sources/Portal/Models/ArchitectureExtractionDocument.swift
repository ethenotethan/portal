import Foundation

// MARK: - The `extraction` section of a hermes.architecture document

/// One declaration with a body in an analysed file (a type, an extension or a
/// function) and the mechanical passes that cited a line inside it. A
/// declaration no pass cited is outside the extractor's grammar: the map says
/// nothing about it.
internal struct ArchitectureExtractedDeclaration: Hashable {
    internal let kind: String
    internal let name: String
    internal let line: Int
    internal let passes: [String]

    internal var isMapped: Bool { !passes.isEmpty }

    internal static func decode(_ value: AnyCodable) -> ArchitectureExtractedDeclaration? {
        guard let d = value.dictionaryValue, let name = d["name"]?.stringValue, let kind = d["kind"]?.stringValue else { return nil }
        return ArchitectureExtractedDeclaration(
            kind: kind,
            name: name,
            line: d["line"]?.intValue ?? 0,
            passes: (d["passes"]?.arrayValue ?? []).compactMap(\.stringValue)
        )
    }
}

/// One analysed source file: what the extractor read, which passes cited it,
/// and the declarations it holds. `touched` is true exactly when a mechanical
/// pass cited a line in it; semantic citations (construct records, flows) are
/// counted separately and never count as extraction.
internal struct ArchitectureExtractedFile: Hashable, Identifiable {
    internal let path: String
    internal let component: String?
    internal let lineCount: Int
    internal let citations: Int
    internal let semanticCitations: Int
    internal let touched: Bool
    internal let declarationCount: Int
    internal let mappedDeclarations: Int
    internal let passes: [String]
    internal let declarations: [ArchitectureExtractedDeclaration]

    internal var id: String { path }

    /// The last path component.
    internal var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }

    /// The path without its last component (empty for a root file).
    internal var directory: String { path.split(separator: "/").dropLast().joined(separator: "/") }

    /// Declarations a pass cited over all declarations; a file with no
    /// declarations counts as fully mapped when touched and empty otherwise.
    internal var mappedShare: Double {
        guard declarationCount > 0 else { return touched ? 1 : 0 }
        return Double(mappedDeclarations) / Double(declarationCount)
    }

    internal static func decode(_ value: AnyCodable) -> ArchitectureExtractedFile? {
        guard let d = value.dictionaryValue, let path = d["path"]?.stringValue, !path.isEmpty else { return nil }
        let declarations = (d["declarations"]?.arrayValue ?? []).compactMap(ArchitectureExtractedDeclaration.decode)
        return ArchitectureExtractedFile(
            path: path,
            component: d["component"]?.stringValue,
            lineCount: d["line_count"]?.intValue ?? 0,
            citations: d["citations"]?.intValue ?? 0,
            semanticCitations: d["semantic_citations"]?.intValue ?? 0,
            touched: d["touched"]?.boolValue ?? ((d["citations"]?.intValue ?? 0) > 0),
            declarationCount: d["declaration_count"]?.intValue ?? declarations.count,
            mappedDeclarations: d["mapped_declarations"]?.intValue ?? declarations.filter(\.isMapped).count,
            passes: (d["passes"]?.arrayValue ?? []).compactMap(\.stringValue),
            declarations: declarations
        )
    }
}

/// Whether a pass is the extractor's own rule or a person's citation.
internal enum ArchitectureExtractionPassClass: Hashable {
    case mechanical
    case semantic
    case custom(String)

    internal init(rawValue: String) {
        switch rawValue {
        case "mechanical": self = .mechanical
        case "semantic": self = .semantic
        default: self = .custom(rawValue)
        }
    }

    internal var rawValue: String {
        switch self {
        case .mechanical: return "mechanical"
        case .semantic: return "semantic"
        case .custom(let value): return value
        }
    }
}

/// One rule of the extractor's grammar: what it recognises, how many files it
/// fired in and how many lines it cited.
internal struct ArchitectureExtractionPass: Hashable, Identifiable {
    internal let id: String
    internal let passClass: ArchitectureExtractionPassClass
    internal let description: String
    internal let files: Int
    internal let citations: Int

    internal var isMechanical: Bool { passClass == .mechanical }

    internal static func decode(_ value: AnyCodable) -> ArchitectureExtractionPass? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureExtractionPass(
            id: id,
            passClass: ArchitectureExtractionPassClass(rawValue: d["class"]?.stringValue ?? "mechanical"),
            description: d["description"]?.stringValue ?? "",
            files: d["files"]?.intValue ?? 0,
            citations: d["citations"]?.intValue ?? 0
        )
    }
}

/// The family a rule belongs to, which is how a wire is coloured. Open so a
/// newer contract minor can add a family without breaking the decoder.
internal enum ArchitectureExtractionFamily: Hashable {
    case store
    case behaviour
    case boundary
    case wiring
    case trigger
    case custom(String)

    internal static let known: [ArchitectureExtractionFamily] = [.store, .behaviour, .boundary, .wiring, .trigger]

    internal init(rawValue: String) {
        switch rawValue {
        case "store": self = .store
        case "behaviour": self = .behaviour
        case "boundary": self = .boundary
        case "wiring": self = .wiring
        case "trigger": self = .trigger
        default: self = .custom(rawValue)
        }
    }

    internal var rawValue: String {
        switch self {
        case .store: return "store"
        case .behaviour: return "behaviour"
        case .boundary: return "boundary"
        case .wiring: return "wiring"
        case .trigger: return "trigger"
        case .custom(let value): return value
        }
    }

    internal var label: String {
        switch self {
        case .store: return "store rules"
        case .behaviour: return "behaviour rules"
        case .boundary: return "boundary signatures"
        case .wiring: return "map wiring"
        case .trigger: return "triggers"
        case .custom(let value): return value
        }
    }
}

/// One extraction: the file and line a rule fired on, and the rule.
internal struct ArchitectureExtractionOrigin: Hashable {
    internal let path: String
    internal let line: Int
    internal let rule: String
    internal let family: ArchitectureExtractionFamily
    internal let via: String?

    internal static func decode(_ value: AnyCodable) -> ArchitectureExtractionOrigin? {
        guard let d = value.dictionaryValue, let path = d["path"]?.stringValue, let rule = d["rule"]?.stringValue else { return nil }
        return ArchitectureExtractionOrigin(
            path: path,
            line: d["line"]?.intValue ?? 0,
            rule: rule,
            family: ArchitectureExtractionFamily(rawValue: d["family"]?.stringValue ?? "wiring"),
            via: d["via"]?.stringValue
        )
    }
}

/// A construction on the system map with every origin it was extracted from.
internal struct ArchitectureExtractedEntity: Hashable, Identifiable {
    internal let id: String
    internal let kind: String
    internal let label: String
    internal let component: String?
    internal let origins: [ArchitectureExtractionOrigin]

    internal static func decode(_ value: AnyCodable) -> ArchitectureExtractedEntity? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureExtractedEntity(
            id: id,
            kind: d["kind"]?.stringValue ?? "node",
            label: d["label"]?.stringValue ?? id,
            component: d["component"]?.stringValue,
            origins: (d["origins"]?.arrayValue ?? []).compactMap(ArchitectureExtractionOrigin.decode)
        )
    }
}

/// A declared-against-mapped pair.
internal struct ArchitectureExtractionCount: Hashable {
    internal let total: Int
    internal let mapped: Int

    internal static let zero = ArchitectureExtractionCount(total: 0, mapped: 0)

    internal var unmapped: Int { max(0, total - mapped) }

    /// Mapped over total in [0, 1]; zero when nothing is declared.
    internal var share: Double { total > 0 ? Double(mapped) / Double(total) : 0 }

    internal static func decode(_ value: AnyCodable?) -> ArchitectureExtractionCount {
        guard let d = value?.dictionaryValue else { return .zero }
        return ArchitectureExtractionCount(total: d["total"]?.intValue ?? 0, mapped: d["mapped"]?.intValue ?? 0)
    }
}

/// The projection reported by construct rather than as a file percentage.
internal struct ArchitectureExtractionSummary: Hashable {
    internal let files: Int
    internal let touchedFiles: Int
    internal let untouchedFiles: Int
    internal let declarations: Int
    internal let mappedDeclarations: Int
    internal let entities: Int
    internal let entitiesWithOrigin: Int
    internal let passes: Int
    internal let citations: Int
    internal let semanticCitations: Int
    internal let byKind: [String: ArchitectureExtractionCount]
    internal let types: ArchitectureExtractionCount
    internal let functions: ArchitectureExtractionCount

    internal static let empty = ArchitectureExtractionSummary(
        files: 0, touchedFiles: 0, untouchedFiles: 0, declarations: 0, mappedDeclarations: 0, entities: 0,
        entitiesWithOrigin: 0, passes: 0, citations: 0, semanticCitations: 0, byKind: [:], types: .zero, functions: .zero
    )

    internal static func decode(_ value: AnyCodable?) -> ArchitectureExtractionSummary {
        guard let d = value?.dictionaryValue else { return .empty }
        var byKind: [String: ArchitectureExtractionCount] = [:]
        for (kind, count) in d["by_kind"]?.dictionaryValue ?? [:] {
            byKind[kind] = ArchitectureExtractionCount.decode(count)
        }
        return ArchitectureExtractionSummary(
            files: d["files"]?.intValue ?? 0,
            touchedFiles: d["touched_files"]?.intValue ?? 0,
            untouchedFiles: d["untouched_files"]?.intValue ?? 0,
            declarations: d["declarations"]?.intValue ?? 0,
            mappedDeclarations: d["mapped_declarations"]?.intValue ?? 0,
            entities: d["entities"]?.intValue ?? 0,
            entitiesWithOrigin: d["entities_with_origin"]?.intValue ?? 0,
            passes: d["passes"]?.intValue ?? 0,
            citations: d["citations"]?.intValue ?? 0,
            semanticCitations: d["semantic_citations"]?.intValue ?? 0,
            byKind: byKind,
            types: ArchitectureExtractionCount.decode(d["types"]),
            functions: ArchitectureExtractionCount.decode(d["functions"])
        )
    }
}

/// The `extraction` section: the compiler as a projection over the tree. Every
/// analysed file with its declarations, every pass that cited source, and every
/// construction on the map with the (file, line, rule) it came from.
internal struct ArchitectureExtractionDocument: Hashable {
    internal let authority: String
    internal let derivation: String
    internal let families: [String: String]
    internal let files: [ArchitectureExtractedFile]
    internal let passes: [ArchitectureExtractionPass]
    internal let entities: [ArchitectureExtractedEntity]
    internal let summary: ArchitectureExtractionSummary

    /// Files by path, for the renderers' lookups.
    internal var fileByPath: [String: ArchitectureExtractedFile] {
        Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Entities by id.
    internal var entityByID: [String: ArchitectureExtractedEntity] {
        Dictionary(entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The `extraction` dictionary of a model, or `nil` when the section is absent.
    /// Tolerant of missing fields: an empty list is a list, not a failure.
    internal static func decode(_ section: [String: AnyCodable]?) -> ArchitectureExtractionDocument? {
        guard let section else { return nil }
        var families: [String: String] = [:]
        for (family, description) in section["families"]?.dictionaryValue ?? [:] {
            families[family] = description.stringValue ?? ""
        }
        return ArchitectureExtractionDocument(
            authority: section["authority"]?.stringValue ?? "observed",
            derivation: section["derivation"]?.stringValue ?? "",
            families: families,
            files: (section["files"]?.arrayValue ?? []).compactMap(ArchitectureExtractedFile.decode),
            passes: (section["passes"]?.arrayValue ?? []).compactMap(ArchitectureExtractionPass.decode),
            entities: (section["entities"]?.arrayValue ?? []).compactMap(ArchitectureExtractedEntity.decode),
            summary: ArchitectureExtractionSummary.decode(section["summary"])
        )
    }

    /// The section of a whole architecture document.
    internal static func decode(document: ArchitectureModelDocument) -> ArchitectureExtractionDocument? {
        decode(document.section(.extraction))
    }
}
