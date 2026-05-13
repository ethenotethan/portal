import Foundation

/// Persists the last known skills list to UserDefaults so SkillsView can render
/// instantly even when the view is recreated (e.g., toggling a sheet/overlay).
@MainActor
enum SkillCache {
    private static let key = "hermes.skillCache.v1"
    private static let timestampKey = "hermes.skillCache.timestamp"

    struct CachedSkills: Codable {
        let categories: [String: [CachedSkillInfo]]
        let timestamp: Date
    }

    struct CachedSkillInfo: Codable {
        let name: String
        let description: String
        let category: String
        let source: String
        let identifier: String?
        let tags: [String]
        let skillMdPath: String?
        let skillDir: String?
        let skillMdPreview: String?
        let skillMdFullContent: String?
        let slashCommand: String
    }

    static func save(categories: [String: [SkillInfo]]) {
        let cached = categories.mapValues { skills in
            skills.map { s in
                CachedSkillInfo(
                    name: s.name,
                    description: s.description,
                    category: s.category,
                    source: s.source,
                    identifier: s.identifier,
                    tags: s.tags,
                    skillMdPath: s.skillMdPath,
                    skillDir: s.skillDir,
                    skillMdPreview: s.skillMdPreview,
                    skillMdFullContent: s.skillMdFullContent,
                    slashCommand: s.slashCommand
                )
            }
        }
        do {
            let data = try JSONEncoder().encode(CachedSkills(categories: cached, timestamp: Date()))
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // Silently fail — cache is best-effort
        }
    }

    static func load() -> [String: [SkillInfo]]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(CachedSkills.self, from: data)
            return decoded.categories.mapValues { skills in
                skills.map { s in
                    SkillInfo(
                        name: s.name,
                        description: s.description,
                        category: s.category,
                        source: s.source,
                        identifier: s.identifier,
                        tags: s.tags,
                        skillMdPath: s.skillMdPath,
                        skillDir: s.skillDir,
                        skillMdPreview: s.skillMdPreview,
                        skillMdFullContent: s.skillMdFullContent,
                        slashCommand: s.slashCommand
                    )
                }
            }
        } catch {
            return nil
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var age: TimeInterval? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(CachedSkills.self, from: data)
            return Date().timeIntervalSince(decoded.timestamp)
        } catch {
            return nil
        }
    }
}
