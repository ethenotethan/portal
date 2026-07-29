import Foundation
import Testing
@testable import Portal

@Suite("Hermes Standard Sessions View Model")
@MainActor
internal struct HermesStandardSessionsViewModelTests {
    @Test("loads upstream sessions into Portal's shared session model")
    internal func loadsSessions() async throws {
        let json = #"""
        {
          "sessions": [{
            "id": "20260729_120000_abcd",
            "title": "Roadmap",
            "preview": "hello",
            "source": "cli",
            "message_count": 7,
            "started_at": 1785326400,
            "last_active": 1785326460,
            "ended_at": null,
            "is_active": true,
            "archived": false
          }],
          "total": 1
        }
        """#
        let data = Data(json.utf8)
        let envelope = try HermesStandardClient.decodeSessions(data)
        let viewModel = HermesStandardSessionsViewModel(
            loader: StubHermesStandardSessionLoader(result: .success(envelope))
        )

        await viewModel.refresh()

        let session = try #require(viewModel.sessions.first)
        #expect(session.id == "20260729_120000_abcd")
        #expect(session.title == "Roadmap")
        #expect(session.messageCount == 7)
        #expect(session.isRunning)
        #expect(session.startedAt == Date(timeIntervalSince1970: 1785326400))
        #expect(viewModel.total == 1)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isLoading)
    }

    @Test("reports load failures without retaining stale rows")
    internal func reportsFailures() async {
        let viewModel = HermesStandardSessionsViewModel(
            loader: StubHermesStandardSessionLoader(result: .failure(HermesStandardError.unauthorized))
        )

        await viewModel.refresh()

        #expect(viewModel.sessions.isEmpty)
        #expect(viewModel.errorMessage == HermesStandardError.unauthorized.errorDescription)
        #expect(!viewModel.isLoading)
    }
}

private final class StubHermesStandardSessionLoader: HermesStandardSessionLoading, @unchecked Sendable {
    private let result: Result<HermesStandardSessionEnvelope, Error>

    fileprivate init(result: Result<HermesStandardSessionEnvelope, Error>) {
        self.result = result
    }

    fileprivate func sessions(limit: Int, offset: Int) async throws -> HermesStandardSessionEnvelope {
        try result.get()
    }
}
