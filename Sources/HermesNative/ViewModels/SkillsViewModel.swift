import Foundation
import SwiftUI
import os.log

@MainActor
@Observable
final class SkillsViewModel {
    var skills: [SkillInfo] = []
    var categories: [String: [SkillInfo]] = [:]
    var isLoading = false
    var errorMessage: String?

    var searchResults: [SkillSearchResult] = []
    var isSearching = false
    var searchQuery = ""
    var installStatus: [String: String] = [:]

    private var gatewayClient: GatewayClient?
    private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SkillsViewModel")

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    func refresh() async {
        guard let client = gatewayClient else {
            log.warning("refresh: gatewayClient is nil")
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let categoriesDict = try await client.listSkills()
            log.info("refresh: listSkills returned \(categoriesDict.count) categories")
            var allSkills: [SkillInfo] = []
            var grouped: [String: [SkillInfo]] = [:]

            if !categoriesDict.isEmpty {
                for (category, names) in categoriesDict {
                    for name in names {
                        let slashCmd = "/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
                        let skill = SkillInfo(
                            name: name,
                            description: "",
                            category: category,
                            source: "local",
                            identifier: nil,
                            tags: [],
                            skillMdPath: nil,
                            skillDir: nil,
                            skillMdPreview: nil,
                            slashCommand: slashCmd
                        )
                        allSkills.append(skill)
                        grouped[category, default: []].append(skill)
                    }
                }
            } else {
                log.info("refresh: listSkills empty, falling back to scanSkillCommands")
                let commandSkills = (try? await client.scanSkillCommands()) ?? []
                log.info("refresh: scanSkillCommands returned \(commandSkills.count) skills")
                for skill in commandSkills {
                    allSkills.append(skill)
                    grouped[skill.category, default: []].append(skill)
                }
            }

            let inspected = await inspectSkills(client, names: allSkills.map { $0.name })
            for i in allSkills.indices {
                if let detail = inspected[allSkills[i].name] {
                    allSkills[i].description = detail.description
                    allSkills[i].skillMdPreview = detail.skillMdPreview
                    allSkills[i].tags = detail.tags
                    allSkills[i].source = detail.source
                }
            }

            self.skills = allSkills.sorted { $0.name.lowercased() < $1.name.lowercased() }
            self.categories = grouped
            log.info("refresh: total \(allSkills.count) skills in \(grouped.count) categories")
        } catch {
            log.error("refresh: error=\(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func inspectSkills(_ client: GatewayClient, names: [String]) async -> [String: SkillInfo] {
        await withTaskGroup(of: (String, SkillInfo?).self) { group in
            for name in names {
                group.addTask { (name, try? await client.inspectSkill(name: name)) }
            }
            var result: [String: SkillInfo] = [:]
            for await (name, info) in group {
                if let info { result[name] = info }
            }
            return result
        }
    }

    func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let client = gatewayClient else { return }
        isSearching = true
        do {
            searchResults = try await client.searchSkills(query: query)
        } catch {
            searchResults = []
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
                _ = try? await client.reloadSkills()
                await refresh()
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
            await refresh()
        } catch {
            installStatus[name] = "failed: \(error.localizedDescription)"
        }
    }

    func reload() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            _ = try await client.reloadSkills()
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    var totalSkills: Int { skills.count }
    var categoryCount: Int { categories.keys.count }
}
