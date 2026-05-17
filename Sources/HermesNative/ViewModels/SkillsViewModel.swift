import Foundation
import SwiftUI
import os.log

@MainActor
@Observable
final class SkillsViewModel {
    // Proxy to SkillCache.shared — single source of truth
    var skills: [SkillInfo] { SkillCache.shared.skills }
    var isLoading: Bool { SkillCache.shared.isLoading }
    var errorMessage: String? { SkillCache.shared.errorMessage }
    var lastRawResponse: String?
    var diagnosticResult: String?

    var searchResults: [SkillSearchResult] = []
    var isSearching = false
    var searchQuery = ""
    var searchError: String?
    var installStatus: [String: String] = [:]
    private var hasLoaded = false

    private var gatewayClient: GatewayClient?
    private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SkillsViewModel")

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
        SkillCache.shared.setGatewayClient(client)
    }

    func refresh() async {
        await SkillCache.shared.reload()
    }

    func refreshIfNeeded() async {
        await SkillCache.shared.refreshIfNeeded()
    }

    func backgroundRefresh() async {
        await SkillCache.shared.backgroundRefresh()
    }

    var totalSkills: Int { skills.count }
    var categoryCount: Int { Set(skills.map { $0.category }).count }
    var categories: [String: [SkillInfo]] {
        Dictionary(grouping: skills) { $0.category }
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let client = gatewayClient else {
            searchError = !query.isEmpty ? "Gateway not connected" : nil
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
                await SkillCache.shared.reload()
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
            await SkillCache.shared.reload()
        } catch {
            installStatus[name] = "failed: \(error.localizedDescription)"
        }
    }

    func reload() async {
        guard let client = gatewayClient else { return }
        _ = try? await client.reloadSkills()
        await SkillCache.shared.reload()
    }

    enum DiagnosticTest {
        case list, scan, search
    }

    func runDiagnostic(_ test: DiagnosticTest) async {
        guard let client = gatewayClient else {
            diagnosticResult = "❌ Gateway client not available"
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
                    output += "  (empty — gateway reported no skills)\n"
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

    func readSkillMarkdown(name: String) async -> String? {
        guard let client = gatewayClient else { return nil }
        do {
            return try await client.readSkillMarkdown(name: name)
        } catch {
            log.error("readSkillMarkdown failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Lazily fetch skill metadata (description, tags, md preview) on expand.
    func inspectSkill(name: String) async {
        guard let client = gatewayClient else { return }
        // Check if we already have metadata
        if let idx = SkillCache.shared.skills.firstIndex(where: { $0.name == name }),
           !SkillCache.shared.skills[idx].description.isEmpty {
            return
        }
        do {
            if let detail = try await client.inspectSkill(name: name) {
                await MainActor.run {
                    if let idx = SkillCache.shared.skills.firstIndex(where: { $0.name == name }) {
                        SkillCache.shared.skills[idx].description = detail.description
                        SkillCache.shared.skills[idx].skillMdPreview = detail.skillMdPreview
                        SkillCache.shared.skills[idx].tags = detail.tags
                        SkillCache.shared.skills[idx].source = detail.source
                    }
                }
            }
        } catch {
            log.error("inspectSkill(\(name)) failed: \(error.localizedDescription)")
        }
    }

    /// Save edited markdown back to the skill.
    func saveSkillMarkdown(name: String, content: String) async -> Bool {
        guard let client = gatewayClient else { return false }
        do {
            let success = try await client.writeSkillMarkdown(name: name, content: content)
            if success {
                // Update SkillCache so the UI reflects changes immediately
                for i in SkillCache.shared.skills.indices where SkillCache.shared.skills[i].name == name {
                    SkillCache.shared.skills[i].skillMdFullContent = content
                    SkillCache.shared.skills[i].skillMdPreview = String(content.prefix(500))
                }
            }
            return success
        } catch {
            log.error("saveSkillMarkdown failed: \(error.localizedDescription)")
            return false
        }
    }
}
