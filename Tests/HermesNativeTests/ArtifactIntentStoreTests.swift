import Combine
import Foundation
import Testing
@testable import HermesNative

// The artifact-action intent state machine (invoke → pending → outcome,
// idempotency-key reuse, confirm round-trip) is driven entirely through the
// gateway. These tests exercise it against a scriptable `FakeArtifactGateway`
// injected into an isolated `ArtifactStore` — no live socket, no shared
// singleton, no on-disk production cache.

// MARK: - Test double

/// A scriptable `ArtifactGateway` for driving `ArtifactStore` intent tests.
/// Records every invoke/confirm/log call and returns pre-loaded results.
@MainActor
private final class FakeArtifactGateway: ArtifactGateway {
    let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()

    // Scripted responses.
    var invokeResult: ArtifactActionInvokeResult?
    var invokeError: Error?
    var confirmResult: ArtifactActionInvokeResult?
    var getArtifact: LivingArtifact?

    // Recorded calls.
    private(set) var invokeCalls: [(artifactID: String, rev: Int, binding: String, entity: String, ikey: String)] = []
    private(set) var confirmCalls: [(artifactID: String, challenge: String)] = []

    func artifactActionInvoke(
        artifactID: String, artifactRev: Int, bindingID: String,
        entityRef: String, idempotencyKey: String
    ) async throws -> ArtifactActionInvokeResult? {
        invokeCalls.append((artifactID, artifactRev, bindingID, entityRef, idempotencyKey))
        if let invokeError { throw invokeError }
        return invokeResult
    }

    func artifactActionConfirm(
        artifactID: String, challenge: String
    ) async throws -> ArtifactActionInvokeResult? {
        confirmCalls.append((artifactID, challenge))
        return confirmResult
    }

    func artifactActionLog(
        artifactID: String, bindingID: String?, limit: Int
    ) async throws -> [[String: AnyCodable]]? { nil }

    func artifactGet(id: String) async throws -> LivingArtifact? { getArtifact }
    func artifactList() async throws -> [LivingArtifact]? { nil }
    func artifactSet(
        id: String, kind: String, content: String, title: String?, replace: Bool
    ) async throws -> LivingArtifact? { nil }
    func artifactDelete(id: String) async throws {}
}

// MARK: - Tests

@Suite("Artifact intent invocation state machine")
@MainActor
private struct ArtifactIntentStoreTests {

    /// A fresh isolated store seeded with one artifact, wired to a fake.
    private func makeStore(
        rev: Int = 3
    ) -> (ArtifactStore, FakeArtifactGateway) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-intent-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        store.seedArtifactForTesting(LivingArtifact(
            id: "issues", kind: "html", title: "Issues", content: "{}",
            updatedAt: Date(timeIntervalSince1970: 0), updatedBy: "test", rev: rev))
        let fake = FakeArtifactGateway()
        store.injectClientForTesting(fake)
        return (store, fake)
    }

    private func slot(_ store: ArtifactStore) -> String {
        store.intentSlotKey(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
    }

    @Test("A succeeded invoke sends the pinned rev + identifiers and lands succeeded")
    func invokeSucceeds() async {
        let (store, fake) = makeStore(rev: 7)
        fake.invokeResult = ArtifactActionInvokeResult(outcome: .succeeded(message: "Archived"))

        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")

        #expect(fake.invokeCalls.count == 1)
        let call = fake.invokeCalls[0]
        #expect(call.artifactID == "issues")
        #expect(call.rev == 7)                       // pinned revision
        #expect(call.binding == "archive")
        #expect(call.entity == "ARC-42")
        #expect(!call.ikey.isEmpty)
        if case .succeeded(let message) = store.intentStates[slot(store)] {
            #expect(message == "Archived")
        } else {
            Issue.record("expected .succeeded, got \(String(describing: store.intentStates[slot(store)]))")
        }
    }

    @Test("A failed outcome surfaces the reason")
    func invokeFails() async {
        let (store, fake) = makeStore()
        fake.invokeResult = ArtifactActionInvokeResult(outcome: .failed(reason: "no such issue"))
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(store.intentStates[slot(store)] == .failed(reason: "no such issue"))
    }

    @Test("needs_confirmation parks the slot with the challenge")
    func invokeNeedsConfirmation() async {
        let (store, fake) = makeStore()
        fake.invokeResult = ArtifactActionInvokeResult(
            outcome: .needsConfirmation(challenge: "chal-1", prompt: "Archive ARC-42?"))
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(store.intentStates[slot(store)] == .needsConfirmation(challenge: "chal-1", prompt: "Archive ARC-42?"))
    }

    @Test("A nil result (method-not-found) maps to unsupported")
    func invokeUnsupported() async {
        let (store, fake) = makeStore()
        fake.invokeResult = nil
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(store.intentStates[slot(store)] == .unsupported)
    }

    @Test("A thrown error maps to failed with the error's description")
    func invokeThrows() async {
        let (store, fake) = makeStore()
        struct Boom: LocalizedError { var errorDescription: String? { "network down" } }
        fake.invokeError = Boom()
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(store.intentStates[slot(store)] == .failed(reason: "network down"))
    }

    @Test("Retrying the same slot reuses the idempotency key")
    func idempotencyKeyReused() async {
        let (store, fake) = makeStore()
        fake.invokeResult = ArtifactActionInvokeResult(outcome: .failed(reason: "transient"))
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(fake.invokeCalls.count == 2)
        #expect(fake.invokeCalls[0].ikey == fake.invokeCalls[1].ikey)
    }

    @Test("Clearing a slot's state issues a fresh idempotency key next time")
    func clearingSlotResetsKey() async {
        let (store, fake) = makeStore()
        fake.invokeResult = ArtifactActionInvokeResult(outcome: .failed(reason: "transient"))
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        store.clearIntentState(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(store.intentStates[slot(store)] == nil)
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(fake.invokeCalls[0].ikey != fake.invokeCalls[1].ikey)
    }

    @Test("confirmIntent sends the challenge and applies the returned outcome")
    func confirmRoundTrip() async {
        let (store, fake) = makeStore()
        fake.confirmResult = ArtifactActionInvokeResult(outcome: .succeeded(message: nil))
        await store.confirmIntent(
            artifactID: "issues", bindingID: "archive", entryKey: "ARC-42", challenge: "chal-1")
        #expect(fake.confirmCalls.count == 1)
        #expect(fake.confirmCalls[0].challenge == "chal-1")
        if case .succeeded = store.intentStates[slot(store)] {} else {
            Issue.record("expected .succeeded after confirm")
        }
    }

    @Test("Invoking with no client wired yields unsupported")
    func invokeWithoutClient() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-intent-noclient-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        store.seedArtifactForTesting(LivingArtifact(
            id: "issues", kind: "html", title: "Issues", content: "{}",
            updatedAt: Date(timeIntervalSince1970: 0), updatedBy: "test", rev: 1))
        await store.invokeIntent(artifactID: "issues", bindingID: "archive", entryKey: "ARC-42")
        #expect(store.intentStates[slot(store)] == .unsupported)
    }
}
