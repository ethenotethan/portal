import Foundation
import Testing
@testable import Portal

/// The learning.* RPC wrappers on `GatewayClient`. A live gateway can't be
/// faked at this layer (the transport is concrete), but every wrapper's
/// request-building half — the param assembly that decides what the gateway
/// is actually asked — runs before the dial and is exercised here against a
/// disconnected client, which `call()` fails fast with `.notConnected`.
/// Getting THROUGH param assembly to that throw is the assertion: a wrapper
/// that trapped or mis-built its params would fail differently.
@Suite("Learning RPC surface")
@MainActor
internal struct LearningRPCSurfaceTests {

    private func disconnectedClient() -> GatewayClient {
        GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:1/v1/ws")!, apiKey: "")
    }

    @Test("every course wrapper builds its params and reaches the transport")
    internal func courseWrappersReachTransport() async {
        let client = disconnectedClient()
        await #expect(throws: GatewayError.self) { _ = try await client.learningCourseList() }
        await #expect(throws: GatewayError.self) { _ = try await client.learningCourseGet(id: "crs-1") }
        await #expect(throws: GatewayError.self) {
            _ = try await client.learningCourseSet(
                id: "crs-1", title: "T", summary: "S", sourceSessionID: "sess-1")
        }
        await #expect(throws: GatewayError.self) {
            _ = try await client.learningCourseSet(
                id: nil, title: "T", summary: "S", sourceSessionID: nil)
        }
        await #expect(throws: GatewayError.self) { try await client.learningCourseDelete(id: "crs-1") }
        await #expect(throws: GatewayError.self) {
            _ = try await client.learningModuleSet(
                courseID: "crs-1", moduleID: "m-1", title: "M", overview: "O", position: 2)
        }
        await #expect(throws: GatewayError.self) {
            _ = try await client.learningModuleSet(
                courseID: "crs-1", moduleID: nil, title: nil, overview: nil, position: nil)
        }
        await #expect(throws: GatewayError.self) {
            _ = try await client.learningStepSet(
                courseID: "crs-1", moduleID: "m-1", stepID: "s-1",
                title: "S", type: "quiz", markdown: nil,
                questions: [["id": "q-1", "q": "?", "options": ["a"], "correct": "A"]])
        }
        await #expect(throws: GatewayError.self) {
            _ = try await client.learningStepSet(
                courseID: "crs-1", moduleID: "m-1", stepID: nil,
                title: nil, type: "lesson", markdown: "# body", questions: nil)
        }
    }

    @Test("every deck and learner-state wrapper builds its params and reaches the transport")
    internal func deckAndStateWrappersReachTransport() async {
        let client = disconnectedClient()
        await #expect(throws: GatewayError.self) { _ = try await client.learningDeckList() }
        await #expect(throws: GatewayError.self) { _ = try await client.learningDeckGet(id: "dk-1") }
        await #expect(throws: GatewayError.self) { _ = try await client.learningDeckSet(id: "dk-1", topic: "t") }
        await #expect(throws: GatewayError.self) { _ = try await client.learningDeckSet(id: nil, topic: "t") }
        await #expect(throws: GatewayError.self) { try await client.learningDeckDelete(id: "dk-1") }
        await #expect(throws: GatewayError.self) {
            _ = try await client.learningCardSet(
                deckID: "dk-1", cards: [["id": "c-1", "front": "f", "back": "b"]])
        }
        await #expect(throws: GatewayError.self) {
            try await client.learningProgressRecord(
                courseID: "crs-1", stepID: "s-1", kind: "quiz_attempt",
                scorePercent: 90, at: Date())
        }
        await #expect(throws: GatewayError.self) {
            try await client.learningProgressRecord(
                courseID: "crs-1", stepID: "s-1", kind: "lesson_read",
                scorePercent: nil, at: nil)
        }
        await #expect(throws: GatewayError.self) {
            try await client.learningReviewRecord(
                deckID: "dk-1", cardID: "c-1", quality: 4,
                reviewedAt: Date(), bootstrapState: ["interval_days": 2.0])
        }
        await #expect(throws: GatewayError.self) {
            try await client.learningReviewRecord(
                deckID: "dk-1", cardID: "c-1", quality: 1,
                reviewedAt: Date(), bootstrapState: nil)
        }
        await #expect(throws: GatewayError.self) {
            try await client.learningAttemptRecord(["topic": "T", "score": 1, "total": 2])
        }
    }
}

/// The chat pipeline's disinterest in learning events, stated as a test: a
/// session-scoped `learning.changed` must pass through `applySessionEvent`
/// as a store-level concern — no transcript mutation, no stream state.
@Suite("Learning events in the chat pipeline")
@MainActor
internal struct LearningEventRoutingTests {

    @Test("learning.changed neither mutates the transcript nor the stream state")
    internal func learningChangedIsAStoreConcern() {
        let vm = ChatViewModel()
        let sid = "learning-route-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(
            .learningChanged(entity: "course", id: "crs-1", rev: 2, deleted: false),
            sessionID: sid
        )

        #expect(vm.messages.isEmpty)
        #expect(!vm.isStreaming)
    }
}
