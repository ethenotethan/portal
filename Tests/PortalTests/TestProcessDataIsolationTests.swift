import Testing
import Foundation
@testable import Portal

/// Coverage for the two guards that keep a unit-test run from writing the
/// user's real, irreplaceable app data.
///
/// Both were written after a live incident. A routine `swift test` run
/// (a) overwrote the stored harness URL and API key in the login Keychain, and
/// (b) wrote fixture transcripts into the real
/// `Application Support/portal/sessions`. The user launched the next build,
/// found a testing default in Settings, re-entered their address by hand, and
/// then could not load their existing sessions — the sidebar's "local-only
/// sessions" source (`localSessionIDs()`) was full of fixture files.
///
/// Note the shape of the original defect: neither test *meant* to touch live
/// state. One assigned a `@Published` property whose `didSet` persists, the
/// other constructed a `ChatViewModel` that saves history on every message
/// change. So both guards live in the production singletons, at the point of
/// the side effect, rather than in the tests that happened to trip them.
@Suite("Test-process data isolation")
internal struct TestProcessDataIsolationTests {

    // MARK: - Keychain

    @Test("live credential accounts are refused in a test process")
    internal func liveAccountsAreRefusedUnderTest() {
        for account in KeychainStore.liveAccounts {
            #expect(
                !KeychainStore.mayWrite(account: account, isTestProcess: true),
                "writing '\(account)' from a test would destroy real credentials"
            )
        }
    }

    @Test("the same accounts are writable in the real app")
    internal func liveAccountsAreWritableInTheApp() {
        // The guard must be inert in production: this is the path that saves
        // the harness the user just typed. A guard that blocked here would
        // turn data loss into a silent failure to save at all.
        for account in KeychainStore.liveAccounts {
            #expect(KeychainStore.mayWrite(account: account, isTestProcess: false))
        }
    }

    @Test("throwaway accounts stay writable under test")
    internal func throwawayAccountsRemainWritable() {
        // Keychain tests scope themselves to generated accounts; the guard must
        // not break them, or it would cost real Keychain coverage.
        #expect(KeychainStore.mayWrite(account: "portal-test-abc123", isTestProcess: true))
        #expect(KeychainStore.mayWrite(account: "centaur-api-key", isTestProcess: true))
    }

    @Test("the guard names exactly the irreplaceable accounts")
    internal func guardCoversTheHarnessTriple() {
        // `gateways` is the whole saved-harness list — one bad write loses every
        // entry — and the other two are the active mirror the app dials.
        #expect(KeychainStore.liveAccounts == ["api-key", "gateway-url", "gateways"])
    }

    @Test("this test process really is detected as one")
    internal func testProcessDetectionWorksHere() {
        // The default argument is what protects production data, so the
        // detection itself has to hold in the runner the suite executes in.
        // Without this, every expectation above could pass while the live
        // guard never engaged.
        #expect(ProcessInfo.isTestProcess)
    }

    // MARK: - Session transcripts

    @Test("session history is redirected away from Application Support")
    @MainActor
    internal func sessionHistoryAvoidsApplicationSupport() {
        let dir = ChatHistoryStore.shared.sessionsDirectoryForTesting.path
        #expect(!dir.contains("Application Support"), "test run would write real session files: \(dir)")
    }

    @Test("saved test transcripts round-trip in the scratch directory")
    @MainActor
    internal func transcriptsRoundTripInScratch() async throws {
        // Redirection must not mean "silently dropped": the store still has to
        // work, because tests assert on what they save.
        let id = "isolation-probe-\(UUID().uuidString)"
        ChatHistoryStore.shared.saveMessages(
            [ChatMessage(role: .user, content: "hello")],
            forSession: id
        )
        // saveMessages writes in a detached task.
        var loaded: [ChatMessage]?
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 20_000_000)
            loaded = ChatHistoryStore.shared.loadMessages(forSession: id)
            if loaded != nil { break }
        }
        #expect(loaded?.first?.content == "hello")
        ChatHistoryStore.shared.deleteMessages(forSession: id)
    }
}
