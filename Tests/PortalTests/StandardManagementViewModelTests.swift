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
