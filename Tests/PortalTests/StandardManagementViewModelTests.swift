import Foundation
import Testing
@testable import Portal

internal actor StandardCronStub: HermesStandardCronManaging {
    private var triggeredID: String?

    internal func cronJobs() async throws -> [HermesStandardCronJob] { [] }

    internal func setCronJob(_ id: String, enabled: Bool) async throws {}

    internal func triggerCronJob(_ id: String) async throws {
        triggeredID = id
    }

    internal func triggered(_ id: String) -> Bool {
        triggeredID == id
    }
}

internal actor StandardSkillStub: HermesStandardSkillManaging {
    private var enabledByName: [String: Bool] = [:]

    internal func skills() async throws -> [HermesStandardSkill] {
        let data = Data(
            #"{"name":"calendar","description":"Calendar","category":"productivity","enabled":true}"#.utf8
        )
        return [try JSONDecoder().decode(HermesStandardSkill.self, from: data)]
    }

    internal func setSkill(_ name: String, enabled: Bool) async throws {
        enabledByName[name] = enabled
    }

    internal func isDisabled(_ name: String) -> Bool {
        enabledByName[name] == false
    }
}

@Suite("Standard management view models")
@MainActor
internal struct StandardManagementViewModelTests {
    @Test("cron routing exposes the supported actions and dispatches triggers")
    internal func cronRouting() async {
        let viewModel = CronListViewModel()
        #expect(viewModel.supportsRemoveAndEdit)
        #expect(!viewModel.supportsTrigger)

        let standard = StandardCronStub()
        viewModel.setStandardClient(standard)
        #expect(!viewModel.supportsRemoveAndEdit)
        #expect(viewModel.supportsTrigger)
        await viewModel.triggerJob(id: "daily")
        #expect(await standard.triggered("daily"))

        viewModel.setGatewayClient(GatewayClient())
        #expect(viewModel.supportsRemoveAndEdit)
        #expect(!viewModel.supportsTrigger)
    }

    @Test("skill routing loads and toggles the Standard skill set")
    internal func skillRouting() async {
        let viewModel = SkillsViewModel()
        #expect(!viewModel.isStandardMode)
        #expect(viewModel.errorMessage == nil)

        let standard = StandardSkillStub()
        viewModel.setStandardClient(standard)
        #expect(viewModel.isStandardMode)
        await viewModel.refreshStandard()
        #expect(viewModel.skills.map(\.name) == ["calendar"])
        #expect(viewModel.standardEnabled["calendar"] == true)

        await viewModel.toggleStandardSkill(name: "calendar")
        #expect(await standard.isDisabled("calendar"))

        viewModel.setGatewayClient(GatewayClient())
        #expect(!viewModel.isStandardMode)
    }
}

@Suite("Cron tags")
@MainActor
internal struct CronTagsTests {
    private func job(
        id: String,
        name: String,
        tags: [String] = [],
        prompt: String? = nil
    ) -> CronJob {
        CronJob(
            id: id,
            name: name,
            schedule: "every 60m",
            nextRunAt: nil,
            lastRunAt: nil,
            lastStatus: nil,
            enabled: true,
            state: "scheduled",
            deliver: "local",
            promptPreview: prompt,
            prompt: prompt,
            lastError: nil,
            tags: tags
        )
    }

    @Test("Gateway cron decoding preserves tags and defaults missing tags to empty")
    internal func gatewayDecoding() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let tagged = GatewayClient.decodeCronJob(from: AnyCodable.dictionary([
            "job_id": AnyCodable("job-1"),
            "name": AnyCodable("Portal CI"),
            "schedule": AnyCodable("every 60m"),
            "tags": AnyCodable.array([AnyCodable("portal"), AnyCodable("ci")])
        ]), using: formatter)
        #expect(try #require(tagged).tags == ["portal", "ci"])

        let legacy = GatewayClient.decodeCronJob(from: AnyCodable.dictionary([
            "job_id": AnyCodable("job-2"),
            "name": AnyCodable("Legacy")
        ]), using: formatter)
        #expect(try #require(legacy).tags.isEmpty)
    }

    @Test("Tag filter and text search match cron tags")
    internal func filtering() {
        let state = CronFilterState()
        let jobs = [
            job(id: "1", name: "Quality Ratchet", tags: ["portal", "ci"]),
            job(id: "2", name: "Wiki Analyzer", tags: ["wiki"]),
            job(id: "3", name: "Backup", tags: ["maintenance"])
        ]

        #expect(state.availableTags(in: jobs) == ["ci", "maintenance", "portal", "wiki"])

        state.selectedTag = "portal"
        #expect(state.apply(to: jobs).map(\.id) == ["1"])

        state.selectedTag = nil
        state.searchText = "maintenance"
        #expect(state.apply(to: jobs).map(\.id) == ["3"])
    }

    @Test("Editor input normalizes comma-separated tags")
    internal func editorNormalization() {
        #expect(CronTagList.parse(" portal, ci, portal,  , maintenance ") == [
            "portal", "ci", "maintenance"
        ])
        #expect(CronTagList.editingText(for: ["portal", "ci"]) == "portal, ci")
    }

    @Test("Detail job resolves the refreshed list value")
    @MainActor
    internal func currentDetailJob() {
        let original = job(id: "1", name: "Ratchet", tags: ["old"])
        let refreshed = job(id: "1", name: "Ratchet", tags: ["new"])
        let viewModel = CronListViewModel()

        #expect(viewModel.currentJob(id: original.id, fallback: original).tags == ["old"])
        viewModel.jobs = [refreshed]
        #expect(viewModel.currentJob(id: original.id, fallback: original).tags == ["new"])
    }
}
