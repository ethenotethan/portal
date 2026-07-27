import Foundation
import SwiftUI
import os

private let log = Logger(subsystem: "com.researchours.HermesNative", category: "SkillStore")

// MARK: - Disk Persistence

@MainActor
enum SkillStoreDisk {
    private static let key = "hermes.skillStore.v2"
    private static let timestampKey = "hermes.skillStore.timestamp"
    private static let versionKey = "hermes.skillStore.version"
    private static let fileStorageKey = "hermes.skillStore.fileMigrated"

    private static let currentVersion = 2

    private static let fileManager = FileManager.default
    private static var storageDir: URL = {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/hermes-native")
        }
        return appSupport.appendingPathComponent("hermes-native", isDirectory: true)
    }()
    private static var skillStoreFile: URL { storageDir.appendingPathComponent("skill-store.json") }

    struct StoredSkills: Codable {
        let skills: [StoredSkillInfo]
        let timestamp: Date
        let version: Int
    }

    struct StoredSkillInfo: Codable {
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

    static func save(_ skills: [SkillInfo]) {
        let stored = skills.map { s in
            StoredSkillInfo(
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
        do {
            let data = try JSONEncoder().encode(StoredSkills(skills: stored, timestamp: Date(), version: currentVersion))
            try fileManager.createDirectory(at: storageDir, withIntermediateDirectories: true)
            try data.write(to: skillStoreFile, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
            UserDefaults.standard.set(currentVersion, forKey: versionKey)
            UserDefaults.standard.set(true, forKey: fileStorageKey)
        } catch {
            log.error("SkillStoreDisk.save failed: \(error.localizedDescription)")
        }
    }

    static func load() -> [SkillInfo]? {
        if UserDefaults.standard.bool(forKey: fileStorageKey) {
            return loadFromFile()
        }
        return loadFromUserDefaults()
    }

    private static func loadFromFile() -> [SkillInfo]? {
        guard fileManager.fileExists(atPath: skillStoreFile.path) else { return nil }
        do {
            let data = try Data(contentsOf: skillStoreFile)
            let decoded = try JSONDecoder().decode(StoredSkills.self, from: data)
            return decoded.skills.map { s in
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
        } catch {
            log.error("SkillStoreDisk.loadFromFile failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func loadFromUserDefaults() -> [SkillInfo]? {
        let version = UserDefaults.standard.integer(forKey: versionKey)
        guard version == currentVersion else {
            log.info("SkillStoreDisk.load: version mismatch (\(version) vs \(currentVersion)), discarding")
            return nil
        }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(StoredSkills.self, from: data)
            let result = decoded.skills.map { s in
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
            // Migrate to file storage on first load
            save(result)
            UserDefaults.standard.removeObject(forKey: key)
            log.info("SkillStoreDisk: migrated from UserDefaults to file (\(result.count) skills)")
            return result
        } catch {
            log.error("SkillStoreDisk.loadFromUserDefaults failed: \(error.localizedDescription)")
            return nil
        }
    }

    static var age: TimeInterval? {
        guard let ts = UserDefaults.standard.object(forKey: timestampKey) as? TimeInterval else { return nil }
        return Date().timeIntervalSince1970 - ts
    }
}

// MARK: - SkillStore

@MainActor
@Observable
internal final class SkillStore {
    static let shared = SkillStore()

    var skills: [SkillInfo] = []
    var isLoading = false
    var errorMessage: String?
    var lastUpdated: Date?
    var isPreFetching = false

    private var gatewayClient: GatewayClient?
    private var preFetchTask: Task<Void, Never>?
    private var syncTimer: Timer?
    private var previousSkillNames: Set<String> = []
    /// One-shot guard: summary pregeneration runs once per app launch.
    /// setGatewayClient is called repeatedly (launch, reconnects, wire-ups);
    /// without this each call spawns another all-skills model sweep.
    private var pregenerationTask: Task<Void, Never>?

    init() {
        if let cached = SkillStoreDisk.load() {
            skills = cached.sorted { $0.name.lowercased() < $1.name.lowercased() }
            previousSkillNames = Set(skills.map { $0.name })
            lastUpdated = Date(timeIntervalSince1970: SkillStoreDisk.age ?? 0)
            log.info("SkillStore init: loaded \(self.skills.count) skills from disk")
        }
    }

    func setGatewayClient(_ client: GatewayClient?) {
        self.gatewayClient = client
        guard client != nil else { return }
        let shouldRefresh = skills.isEmpty || needsRefresh
        // Start the local model load + a one-shot refresh-then-pregenerate
        // pass. setGatewayClient is called repeatedly (launch, reconnects,
        // wire-ups); without the task guard each call stacks another
        // concurrent all-skills model sweep and pins the CPU.
        guard pregenerationTask == nil else {
            if shouldRefresh {
                Task.detached(priority: .background) { [weak self] in
                    await self?.refreshSkillList()
                }
            }
            return
        }
        SkillSummaryService.shared.warmUp()
        pregenerationTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            if shouldRefresh {
                await self.refreshSkillList()
            }
            await self.pregenerateSummaries()
        }
    }

    /// Fast refresh: list skills from gateway without fetching full details.
    /// Skill content is lazy-loaded when the user types a slash command.
    private func refreshSkillList() async {
        guard let client = gatewayClient, !isPreFetching else { return }
        isPreFetching = true
        do {
            let categoriesDict = try await client.listSkills()
            var allSkills: [SkillInfo] = []

            for (category, names) in categoriesDict {
                for name in names {
                    let slashCmd = "/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                    let existing = skills.first { $0.name == name }
                    allSkills.append(SkillInfo(
                        name: name,
                        description: existing?.description ?? "",
                        category: category,
                        source: existing?.source ?? "local",
                        identifier: existing?.identifier,
                        tags: existing?.tags ?? [],
                        skillMdPath: existing?.skillMdPath,
                        skillDir: existing?.skillDir,
                        skillMdPreview: existing?.skillMdPreview,
                        skillMdFullContent: existing?.skillMdFullContent,
                        slashCommand: existing?.slashCommand ?? slashCmd
                    ))
                }
            }

            if allSkills.isEmpty {
                let commands = (try? await client.scanSkillCommands()) ?? []
                if !commands.isEmpty { allSkills = commands }
            }

            skills = allSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            lastUpdated = Date()
            persistToDisk()
        } catch {
            log.error("SkillStore.refreshSkillList error: \(error.localizedDescription)")
        }
        isPreFetching = false
    }

    // MARK: - Public API

    func refreshIfNeeded() async {
        guard let client = gatewayClient else { return }
        if skills.isEmpty {
            await load(client: client)
        } else if needsRefresh {
            await backgroundRefresh(client: client)
        }
    }

    func reload() async {
        guard let client = gatewayClient else { return }
        await load(client: client)
    }

    func backgroundRefresh() async {
        guard let client = gatewayClient else { return }
        await backgroundRefresh(client: client)
    }

    func preFetchAll() async {
        guard let client = gatewayClient, !isPreFetching else { return }
        isPreFetching = true
        log.info("SkillStore.preFetchAll starting")

        do {
            let categoriesDict = try await client.listSkills()
            var allSkills: [SkillInfo] = []

            for (category, names) in categoriesDict {
                for name in names {
                    let slashCmd = "/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                    let existing = skills.first { $0.name == name }
                    allSkills.append(SkillInfo(
                        name: name,
                        description: existing?.description ?? "",
                        category: category,
                        source: existing?.source ?? "local",
                        identifier: existing?.identifier,
                        tags: existing?.tags ?? [],
                        skillMdPath: existing?.skillMdPath,
                        skillDir: existing?.skillDir,
                        skillMdPreview: existing?.skillMdPreview,
                        skillMdFullContent: existing?.skillMdFullContent,
                        slashCommand: existing?.slashCommand ?? slashCmd
                    ))
                }
            }

            if allSkills.isEmpty {
                let commands = (try? await client.scanSkillCommands()) ?? []
                if !commands.isEmpty {
                    allSkills = commands
                }
            }

            let newNames = Set(allSkills.map { $0.name })

            let added = newNames.subtracting(previousSkillNames)
            let removed = previousSkillNames.subtracting(newNames)
            if !added.isEmpty || !removed.isEmpty {
                log.info("SkillStore sync: +\(added.count) added, -\(removed.count) removed")
            }

            skills = allSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            previousSkillNames = newNames
            lastUpdated = Date()
            persistToDisk()

            let toInspect = skills.enumerated().filter { $0.element.description.isEmpty }
            isPreFetching = false
            log.info("SkillStore.preFetchAll: \(self.skills.count) skills listed, \(toInspect.count) to inspect")

            for (idx, skill) in toInspect {
                if Task.isCancelled { break }
                do {
                    if let detail = try await client.inspectSkill(name: skill.name) {
                        skills[idx].description = detail.description
                        skills[idx].skillMdPreview = detail.skillMdPreview
                        skills[idx].tags = detail.tags
                        skills[idx].source = detail.source
                        if let path = detail.skillMdPath { skills[idx].skillMdPath = path }
                        if let dir = detail.skillDir { skills[idx].skillDir = dir }
                        if let id = detail.identifier { skills[idx].identifier = id }
                    }
                } catch {
                    log.warning("SkillStore.preFetchAll inspectSkill(\(skill.name)) failed: \(error.localizedDescription)")
                }
                // Throttle: space out RPCs to avoid saturating the WebSocket
                // and competing with session create/prompt submits.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            persistToDisk()
            log.info("SkillStore.preFetchAll done: \(self.skills.count) skills fully loaded")
        } catch {
            log.error("SkillStore.preFetchAll error: \(error.localizedDescription)")
            isPreFetching = false
        }
    }

    func readSkillContent(name: String) async -> String? {
        if let idx = skills.firstIndex(where: { $0.name == name }),
           let content = skills[idx].skillMdFullContent, !content.isEmpty {
            return content
        }
        guard let client = gatewayClient else { return nil }
        do {
            let content = try await client.readSkillMarkdown(name: name)
            if !content.isEmpty, let idx = skills.firstIndex(where: { $0.name == name }) {
                skills[idx].skillMdFullContent = content
                skills[idx].skillMdPreview = String(content.prefix(500))
                persistToDisk()
            }
            return content
        } catch {
            log.error("SkillStore.readSkillContent failed: \(error.localizedDescription)")
            return nil
        }
    }

    func updateSkillContent(name: String, content: String) {
        for i in skills.indices where skills[i].name == name {
            skills[i].skillMdFullContent = content
            skills[i].skillMdPreview = String(content.prefix(500))
        }
        persistToDisk()
    }

    /// Background-generate AI summaries for every skill into the on-disk
    /// summary cache, so expanding a card resolves instantly instead of
    /// kicking off generation on demand. Warms the local model first; each
    /// uncached skill queues through the service's serialized generation
    /// (one model call at a time). Idempotent: cached skills are skipped.
    func pregenerateSummaries() async {
        await SkillSummaryService.shared.prepareModel()
        let names = skills.map { $0.name }
        for name in names {
            // Resolve content (cached field or RPC fetch) for the cache-key hash.
            guard let markdown = await readSkillContent(name: name), !markdown.isEmpty else { continue }
            if SkillSummaryService.shared.hasCachedSummary(name: name, markdown: markdown) { continue }
            _ = await SkillSummaryService.shared.summarize(name: name, markdown: markdown)
        }
    }

    func syncWithGateway() async {
        guard let client = gatewayClient else { return }
        await backgroundRefresh(client: client)
    }

    // MARK: - Private

    private var needsRefresh: Bool {
        guard let last = lastUpdated else { return true }
        return Date().timeIntervalSince(last) > 60
    }

    private func load(client: GatewayClient) async {
        isLoading = true
        errorMessage = nil

        do {
            let categoriesDict = try await client.listSkills()
            log.info("SkillStore.load listSkills → \(categoriesDict.count) categories")

            var allSkills: [SkillInfo] = []

            for (category, names) in categoriesDict {
                for name in names {
                    let slashCmd = "/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                    let existing = skills.first { $0.name == name }
                    allSkills.append(SkillInfo(
                        name: name,
                        description: existing?.description ?? "",
                        category: category,
                        source: existing?.source ?? "local",
                        identifier: existing?.identifier,
                        tags: existing?.tags ?? [],
                        skillMdPath: existing?.skillMdPath,
                        skillDir: existing?.skillDir,
                        skillMdPreview: existing?.skillMdPreview,
                        skillMdFullContent: existing?.skillMdFullContent,
                        slashCommand: existing?.slashCommand ?? slashCmd
                    ))
                }
            }

            if allSkills.isEmpty {
                let commands = (try? await client.scanSkillCommands()) ?? []
                if !commands.isEmpty {
                    allSkills = commands
                }
            }

            let newNames = Set(allSkills.map { $0.name })
            let added = newNames.subtracting(previousSkillNames)
            let removed = previousSkillNames.subtracting(newNames)
            if !added.isEmpty || !removed.isEmpty {
                log.info("SkillStore sync: +\(added.count) added, -\(removed.count) removed")
            }

            skills = allSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            previousSkillNames = newNames
            lastUpdated = Date()

            if !allSkills.isEmpty {
                persistToDisk()
            }

            preFetchTask?.cancel()
            preFetchTask = Task { @MainActor in
                await refreshSkillList()
                isLoading = false
            }
        } catch {
            log.error("SkillStore.load error: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func backgroundRefresh(client: GatewayClient) async {
        do {
            let categoriesDict = try await client.listSkills()
            var allSkills: [SkillInfo] = []

            for (category, names) in categoriesDict {
                for name in names {
                    let slashCmd = "/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                    let existing = skills.first { $0.name == name }
                    allSkills.append(SkillInfo(
                        name: name,
                        description: existing?.description ?? "",
                        category: category,
                        source: existing?.source ?? "local",
                        identifier: existing?.identifier,
                        tags: existing?.tags ?? [],
                        skillMdPath: existing?.skillMdPath,
                        skillDir: existing?.skillDir,
                        skillMdPreview: existing?.skillMdPreview,
                        skillMdFullContent: existing?.skillMdFullContent,
                        slashCommand: existing?.slashCommand ?? slashCmd
                    ))
                }
            }

            if allSkills.isEmpty {
                let commands = (try? await client.scanSkillCommands()) ?? []
                if !commands.isEmpty { allSkills = commands }
            }

            let newNames = Set(allSkills.map { $0.name })
            let added = newNames.subtracting(previousSkillNames)
            let removed = previousSkillNames.subtracting(newNames)

            if !added.isEmpty || !removed.isEmpty {
                log.info("SkillStore background sync: +\(added.count) added, -\(removed.count) removed")
            }

            skills = allSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            previousSkillNames = newNames
            lastUpdated = Date()
            persistToDisk()

            let needsInspect = allSkills.filter { $0.description.isEmpty }
            if !needsInspect.isEmpty {
                Task { @MainActor in
                    await preFetchMissingDetails(needsInspect, client: client)
                }
            }
        } catch {
            log.error("SkillStore.backgroundRefresh error: \(error.localizedDescription)")
        }
    }

    private func preFetchMissingDetails(_ targets: [SkillInfo], client: GatewayClient) async {
        for skill in targets {
            guard let idx = skills.firstIndex(where: { $0.name == skill.name }),
                  skills[idx].description.isEmpty else { continue }
            do {
                if let detail = try await client.inspectSkill(name: skill.name) {
                    skills[idx].description = detail.description
                    skills[idx].skillMdPreview = detail.skillMdPreview
                    skills[idx].tags = detail.tags
                    skills[idx].source = detail.source
                    if let path = detail.skillMdPath { skills[idx].skillMdPath = path }
                    if let dir = detail.skillDir { skills[idx].skillDir = dir }
                    if let id = detail.identifier { skills[idx].identifier = id }
                }
            } catch {
                log.warning("SkillStore preFetchMissingDetails(\(skill.name)) failed: \(error.localizedDescription)")
            }
            await Task.yield()
        }
        persistToDisk()
    }

    private func persistToDisk() {
        SkillStoreDisk.save(skills)
    }
}
