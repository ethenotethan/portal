import Foundation
import SwiftUI
import os.log

/// The subset of the upstream Hermes dashboard HTTP API the native skills view
/// needs: list and enable/disable. `HermesStandardClient` implements both.
internal protocol HermesStandardSkillManaging: Sendable {
    func skills() async throws -> [HermesStandardSkill]
    func setSkill(_ name: String, enabled: Bool) async throws
}

extension HermesStandardClient: HermesStandardSkillManaging {}

@MainActor
@Observable
internal final class SkillsViewModel {
    /// Skills to render. In Standard mode this is the HTTP list held locally
    /// (deliberately NOT routed through `SkillStore`, whose disk cache belongs
    /// to the WebSocket Gateway's skill set — mixing the two would clobber it).
    internal var skills: [SkillInfo] { standardClient == nil ? SkillStore.shared.skills : standardSkills }
    internal var isLoading: Bool {
        standardClient == nil ? (SkillStore.shared.isLoading || SkillStore.shared.isPreFetching) : standardLoading
    }
    internal var errorMessage: String? { standardClient == nil ? SkillStore.shared.errorMessage : standardError }
    var lastRawResponse: String?
    var diagnosticResult: String?

    var searchResults: [SkillSearchResult] = []
    var isSearching = false
    var searchQuery = ""
    var searchError: String?
    var installStatus: [String: String] = [:]
    var skillSummaries: [String: SkillSummaryService.SummaryState] = [:]
    private var hasLoaded = false

    private var gatewayClient: GatewayClient?
    private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "SkillsViewModel")

    // MARK: - Standard (HTTP) mode

    /// When set, skills read/toggle over the upstream Hermes dashboard HTTP API
    /// instead of the WebSocket `SkillStore`. A Standard backend is HTTP-only.
    private var standardClient: (any HermesStandardSkillManaging)?
    private var standardSkills: [SkillInfo] = []
    /// Per-skill enabled state, keyed by name. `SkillInfo` has no `enabled`
    /// field (it predates a toggle), so the view model carries it alongside.
    internal private(set) var standardEnabled: [String: Bool] = [:]
    private var standardLoading = false
    private var standardError: String?

    /// True when skills come from a Standard backend — the view then shows the
    /// enable/disable toggle and hides install/uninstall/search (Standard's API
    /// manages a fixed local skill set, not a hub).
    internal var isStandardMode: Bool { standardClient != nil }

    internal func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
        standardClient = nil
        standardSkills = []
        standardEnabled = [:]
        SkillStore.shared.setGatewayClient(client)
    }

    /// Point the view model at an upstream Hermes dashboard (Standard backend).
    /// Leaves `SkillStore` untouched so the WebSocket skill set/cache survives.
    internal func setStandardClient(_ client: any HermesStandardSkillManaging) {
        standardClient = client
        gatewayClient = nil
    }

    /// Load skills from the Standard dashboard API. No-op outside Standard mode.
    internal func refreshStandard() async {
        guard let standardClient else { return }
        standardLoading = true
        standardError = nil
        do {
            let upstream = try await standardClient.skills()
            standardSkills = upstream
                .map(SkillInfo.init(standard:))
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            standardEnabled = Dictionary(upstream.map { ($0.name, $0.enabled) }, uniquingKeysWith: { _, new in new })
        } catch {
            standardSkills = []
            standardError = error.localizedDescription
            log.error("Standard skills load failed: \(error.localizedDescription)")
        }
        standardLoading = false
    }

    /// Enable/disable a Standard skill via `/api/skills/toggle`, optimistically
    /// flipping local state then reconciling from a reload. No-op off Standard.
    internal func toggleStandardSkill(name: String) async {
        guard let standardClient else { return }
        let target = !(standardEnabled[name] ?? true)
        standardEnabled[name] = target
        do {
            try await standardClient.setSkill(name, enabled: target)
            await refreshStandard()
        } catch {
            standardEnabled[name] = !target
            standardError = error.localizedDescription
            log.error("Standard skill toggle failed for \(name): \(error.localizedDescription)")
        }
    }

    func refresh() async {
        await SkillStore.shared.reload()
    }

    func refreshIfNeeded() async {
        await SkillStore.shared.refreshIfNeeded()
    }

    func backgroundRefresh() async {
        await SkillStore.shared.backgroundRefresh()
    }

    var totalSkills: Int { skills.count }
    var categoryCount: Int { Set(skills.map { $0.category }).count }
    var categories: [String: [SkillInfo]] {
        Dictionary(grouping: skills) { $0.category }
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let client = gatewayClient else {
            searchError = !query.isEmpty ? "Harness not connected" : nil
            return
        }
        isSearching = true
        searchError = nil
        do {
            searchResults = try await client.searchSkills(query: query)
        } catch {
            searchResults = []
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    func installSkill(name: String) async {
        guard let client = gatewayClient else { return }
        installStatus[name] = "installing"
        do {
            let success = try await client.installSkill(name: name)
            installStatus[name] = success ? "installed" : "failed"
            if success {
                CelebrationManager.shared.onSkillInstalled(name: name)
                _ = try? await client.reloadSkills()
                await SkillStore.shared.reload()
            }
        } catch {
            installStatus[name] = "failed: \(error.localizedDescription)"
        }
    }

    func uninstallSkill(name: String) async {
        guard let client = gatewayClient else { return }
        installStatus[name] = "uninstalling"
        do {
            _ = try await client.uninstallSkill(name: name)
            installStatus[name] = nil
            _ = try? await client.reloadSkills()
            await SkillStore.shared.reload()
        } catch {
            installStatus[name] = "failed: \(error.localizedDescription)"
        }
    }

    func reload() async {
        guard let client = gatewayClient else { return }
        _ = try? await client.reloadSkills()
        await SkillStore.shared.reload()
    }

    enum DiagnosticTest {
        case list, scan, search
    }

    func runDiagnostic(_ test: DiagnosticTest) async {
        guard let client = gatewayClient else {
            diagnosticResult = "❌ Harness client not available"
            return
        }
        var output = "Running \(String(describing: test))...\n"
        do {
            switch test {
            case .list:
                let result = try await client.listSkills()
                output += "✅ listSkills returned \(result.count) categories:\n"
                for (cat, names) in result.sorted(by: { $0.key < $1.key }) {
                    output += "  • \(cat): \(names.joined(separator: ", "))\n"
                }
                if result.isEmpty {
                    output += "  (empty — harness reported no skills)\n"
                }
            case .scan:
                let result = try await client.scanSkillCommands()
                output += "✅ scanSkillCommands returned \(result.count) commands:\n"
                for skill in result {
                    output += "  • \(skill.name) — \(skill.category)\n"
                }
                if result.isEmpty {
                    output += "  (empty — no slash commands found)\n"
                }
            case .search:
                let query = searchQuery.trimmingCharacters(in: .whitespaces)
                guard !query.isEmpty else {
                    output += "⚠️ Enter a search query first\n"
                    diagnosticResult = output
                    return
                }
                let result = try await client.searchSkills(query: query)
                output += "✅ searchSkills(\"\(query)\") returned \(result.count) results:\n"
                for r in result {
                    output += "  • \(r.name) — \(r.description)\n"
                }
                if result.isEmpty {
                    output += "  (empty — no matches)\n"
                }
            }
        } catch {
            output += "❌ Error: \(error.localizedDescription)\n"
        }
        diagnosticResult = output
    }

    func requestSummary(for skill: SkillInfo) async {
        switch skillSummaries[skill.name] {
        case .ready, .generating: return
        default: break
        }

        var markdown = skill.skillMdFullContent ?? skill.skillMdPreview
        if markdown == nil || markdown?.isEmpty == true {
            markdown = await readSkillMarkdown(name: skill.name)
        }
        guard let markdown, !markdown.isEmpty else {
            skillSummaries[skill.name] = .failed("No skill content")
            return
        }

        if let cached = SkillSummaryService.shared.cachedSummary(name: skill.name, markdown: markdown) {
            skillSummaries[skill.name] = .ready(cached)
            return
        }

        skillSummaries[skill.name] = .generating
        switch await SkillSummaryService.shared.summarize(name: skill.name, markdown: markdown) {
        case .success(let summary):
            skillSummaries[skill.name] = .ready(summary)
        case .failure(let error):
            skillSummaries[skill.name] = .failed(error.localizedDescription)
        }
    }

    func readSkillMarkdown(name: String) async -> String? {
        guard let client = gatewayClient else { return nil }
        do {
            return try await client.readSkillMarkdown(name: name)
        } catch {
            log.error("readSkillMarkdown failed: \(error.localizedDescription)")
            return nil
        }
    }

    func saveSkillMarkdown(name: String, content: String) async -> Bool {
        guard let client = gatewayClient else { return false }
        do {
            let success = try await client.writeSkillMarkdown(name: name, content: content)
            if success {
                SkillStore.shared.updateSkillContent(name: name, content: content)
            }
            return success
        } catch {
            log.error("saveSkillMarkdown failed: \(error.localizedDescription)")
            return false
        }
    }
}
