import Foundation

struct SkillInfo: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String
    var category: String
    var source: String
    var identifier: String?
    var tags: [String]
    var skillMdPath: String?
    var skillDir: String?
    var skillMdPreview: String?
    var skillMdFullContent: String?
    var slashCommand: String

    static func fromCommandEntry(key: String, dict: [String: AnyCodable]) -> SkillInfo {
        SkillInfo(
            name: dict["name"]?.stringValue ?? key,
            description: dict["description"]?.stringValue ?? "",
            category: "general",
            source: "local",
            identifier: nil,
            tags: [],
            skillMdPath: dict["skill_md_path"]?.stringValue,
            skillDir: dict["skill_dir"]?.stringValue,
            skillMdPreview: nil,
            skillMdFullContent: nil,
            slashCommand: key
        )
    }

    static func fromInspectDict(_ d: [String: AnyCodable]) -> SkillInfo? {
        guard let name = d["name"]?.stringValue, !name.isEmpty else { return nil }
        return SkillInfo(
            name: name,
            description: d["description"]?.stringValue ?? "",
            category: d["category"]?.stringValue ?? "general",
            source: d["source"]?.stringValue ?? "local",
            identifier: d["identifier"]?.stringValue,
            tags: d["tags"]?.arrayValue?.map { $0.stringValue ?? "" } ?? [],
            skillMdPath: d["skill_md_path"]?.stringValue,
            skillDir: d["skill_dir"]?.stringValue,
            skillMdPreview: d["skill_md_preview"]?.stringValue,
            skillMdFullContent: d["skill_md_full"]?.stringValue ?? d["content"]?.stringValue,
            slashCommand: d["slash_command"]?.stringValue ?? "/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
    }
}

struct SkillSearchResult: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var description: String

    static func from(_ d: [String: AnyCodable]) -> SkillSearchResult? {
        guard let name = d["name"]?.stringValue, !name.isEmpty else { return nil }
        return SkillSearchResult(
            name: name,
            description: d["description"]?.stringValue ?? ""
        )
    }
}

struct SkillsReloadResult {
    var output: String
    var added: [String]
    var removed: [String]
    var total: Int
}
