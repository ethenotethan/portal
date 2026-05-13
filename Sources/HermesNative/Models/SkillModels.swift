import Foundation

enum SkillNodeKind: String, Codable, Hashable {
    case directory
    case skill
    case file
}

struct SkillSummary: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let category: String?
    let description: String
    let path: String
    let tags: [String]
    let relatedSkills: [String]
    let readOnly: Bool
    let source: String

    static func from(_ d: [String: AnyCodable]) -> SkillSummary? {
        let id = d["id"]?.stringValue ?? ""
        guard !id.isEmpty else { return nil }
        return SkillSummary(
            id: id,
            name: d["name"]?.stringValue ?? id,
            category: d["category"]?.stringValue.nilIfEmpty,
            description: d["description"]?.stringValue ?? "",
            path: d["path"]?.stringValue ?? "",
            tags: d["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            relatedSkills: d["related_skills"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            readOnly: d["read_only"]?.boolValue ?? false,
            source: d["source"]?.stringValue ?? "local"
        )
    }
}

struct SkillFileNode: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let kind: SkillNodeKind
    let path: String?
    let skillID: String?
    let readOnly: Bool
    let children: [SkillFileNode]

    static func from(_ d: [String: AnyCodable]) -> SkillFileNode? {
        let id = d["id"]?.stringValue ?? d["path"]?.stringValue ?? d["name"]?.stringValue ?? ""
        guard !id.isEmpty else { return nil }
        let kind = SkillNodeKind(rawValue: d["kind"]?.stringValue ?? "file") ?? .file
        return SkillFileNode(
            id: id,
            name: d["name"]?.stringValue ?? id,
            kind: kind,
            path: d["path"]?.stringValue,
            skillID: d["skill_id"]?.stringValue,
            readOnly: d["read_only"]?.boolValue ?? false,
            children: d["children"]?.arrayValue?.compactMap { item in
                guard let child = item.dictionaryValue else { return nil }
                return SkillFileNode.from(child)
            } ?? []
        )
    }
}

struct SkillDocument: Hashable {
    let skill: SkillSummary
    let filePath: String
    let content: String
    let readOnly: Bool

    static func from(_ d: [String: AnyCodable]) -> SkillDocument? {
        guard let skillDict = d["skill"]?.dictionaryValue,
              let skill = SkillSummary.from(skillDict) else { return nil }
        return SkillDocument(
            skill: skill,
            filePath: d["file_path"]?.stringValue ?? "SKILL.md",
            content: d["content"]?.stringValue ?? "",
            readOnly: d["read_only"]?.boolValue ?? skill.readOnly
        )
    }
}

struct SkillGraphNode: Identifiable, Hashable, Codable {
    let id: String
    let label: String
    let category: String?
    let tags: [String]
    let description: String

    static func from(_ d: [String: AnyCodable]) -> SkillGraphNode? {
        let id = d["id"]?.stringValue ?? ""
        guard !id.isEmpty else { return nil }
        return SkillGraphNode(
            id: id,
            label: d["label"]?.stringValue ?? id,
            category: d["category"]?.stringValue.nilIfEmpty,
            tags: d["tags"]?.arrayValue?.compactMap { $0.stringValue } ?? [],
            description: d["description"]?.stringValue ?? ""
        )
    }
}

struct SkillGraphEdge: Identifiable, Hashable, Codable {
    var id: String { "\(source)->\(target):\(type)" }
    let source: String
    let target: String
    let type: String

    static func from(_ d: [String: AnyCodable]) -> SkillGraphEdge? {
        guard let source = d["source"]?.stringValue,
              let target = d["target"]?.stringValue else { return nil }
        return SkillGraphEdge(
            source: source,
            target: target,
            type: d["type"]?.stringValue ?? "related_skill"
        )
    }
}

struct SkillGraph: Hashable, Codable {
    let nodes: [SkillGraphNode]
    let edges: [SkillGraphEdge]

    static let empty = SkillGraph(nodes: [], edges: [])

    static func from(_ d: [String: AnyCodable]) -> SkillGraph {
        SkillGraph(
            nodes: d["nodes"]?.arrayValue?.compactMap { item in
                guard let node = item.dictionaryValue else { return nil }
                return SkillGraphNode.from(node)
            } ?? [],
            edges: d["edges"]?.arrayValue?.compactMap { item in
                guard let edge = item.dictionaryValue else { return nil }
                return SkillGraphEdge.from(edge)
            } ?? []
        )
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}
