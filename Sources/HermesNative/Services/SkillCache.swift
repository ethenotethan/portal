import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SkillCache")

// MARK: - Disk Persistence (legacy static interface)

/// Persists the last known skills list to UserDefaults so SkillsView can render
/// instantly even when the view is recreated.
@MainActor
enum SkillCacheDisk {
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
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
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

    static var age: TimeInterval? {
        guard let ts = UserDefaults.standard.object(forKey: timestampKey) as? TimeInterval else { return nil }
        return Date().timeIntervalSince1970 - ts
    }
}

// MARK: - Live Observable Cache

/// Shared skill cache that persists across navigations.
/// Background-refreshes on a timer and on demand; publishes diff-based updates.
@MainActor
@Observable
final class SkillCache {
    static let shared = SkillCache()

    var skills: [SkillInfo] = []
    var isLoading = false
    var errorMessage: String?
    var lastUpdated: Date?

    /// Load cached skills from disk into memory on init.
    init() {
        if let cached = SkillCacheDisk.load() {
            skills = cached.values.flatMap { $0 }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            lastUpdated = Date(timeIntervalSince1970: SkillCacheDisk.age ?? 0)
        }
    }

    /// Scan all slash commands from the gateway — lightweight
    private var gatewayClient: GatewayClient?

    func setGatewayClient(_ client: GatewayClient?) {
        self.gatewayClient = client
    }

    /// Load from cache if available, then refresh in background.
    func refreshIfNeeded() async {
        guard let client = gatewayClient else { return }
        if !skills.isEmpty { return } // Already have data
        await load(cached: false, client: client)
    }

    /// Force reload — replaces cache with fresh data.
    func reload() async {
        guard let client = gatewayClient else { return }
        await load(cached: false, client: client)
    }

    /// Silent background refresh — diff-merges to avoid UI jumps.
    func backgroundRefresh() async {
        guard let client = gatewayClient else { return }
        await load(cached: true, client: client)
    }

    /// Read full SKILL.md content for a single skill.
    func readSkillContent(name: String) async -> String? {
        guard let client = gatewayClient else { return nil }
        do {
            return try await client.readSkillMarkdown(name: name)
        } catch {
            log.error("readSkillContent failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private

    /// Lightweight load: just fetch skill names/categories from gateway.
    /// Full metadata (description, tags, md preview) is fetched lazily on expand.
    private func load(cached: Bool, client: GatewayClient) async {
        if !cached { isLoading = true }
        errorMessage = nil

        do {
            let categoriesDict = try await client.listSkills()
            log.info("SkillCache.load listSkills → \(categoriesDict.count) categories")

            var allSkills: [SkillInfo] = []

            for (category, names) in categoriesDict {
                for name in names {
                    let slashCmd = "/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                    allSkills.append(SkillInfo(
                        name: name, description: "", category: category,
                        source: "local", identifier: nil, tags: [],
                        skillMdPath: nil, skillDir: nil, skillMdPreview: nil,
                        skillMdFullContent: nil, slashCommand: slashCmd
                    ))
                }
            }

            if allSkills.isEmpty {
                // Fallback: try scanning slash commands
                let commands = (try? await client.scanSkillCommands()) ?? []
                if !commands.isEmpty {
                    log.info("SkillCache.load scan → \(commands.count) commands")
                    allSkills = commands
                }
            }

            // Preserve any lazy-loaded content from existing skills
            var oldContent: [String: (description: String, tags: [String], source: String,
                                      skillMdPreview: String?, skillMdFullContent: String?)] = [:]
            for s in self.skills {
                oldContent[s.name] = (s.description, s.tags, s.source, s.skillMdPreview, s.skillMdFullContent)
            }

            for i in allSkills.indices {
                let name = allSkills[i].name
                if let existing = oldContent[name] {
                    allSkills[i].description = existing.description
                    allSkills[i].tags = existing.tags
                    allSkills[i].source = existing.source
                    allSkills[i].skillMdPreview = existing.skillMdPreview
                    allSkills[i].skillMdFullContent = existing.skillMdFullContent
                }
            }

            self.skills = allSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            log.info("SkillCache.load done: \(self.skills.count) skills (metadata lazy)")

            // Only persist to disk if we actually got data
            if !allSkills.isEmpty {
                let dict = Dictionary(grouping: allSkills) { $0.category }
                SkillCacheDisk.save(categories: dict)
            }
        } catch {
            log.error("SkillCache.load error: \(error.localizedDescription)")
            if !cached { errorMessage = error.localizedDescription }
        }

        if !cached { isLoading = false }
    }
}
