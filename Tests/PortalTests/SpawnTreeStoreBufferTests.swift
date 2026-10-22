import Testing
import Foundation
@testable import Portal

/// Events for a session with no Mission Control tree are buffered so a tree
/// created a moment later can replay them. A tree is only ever created for a
/// session this app starts, so for every other session the buffer was the final
/// resting place of every lifecycle event for the life of the process. It is
/// bounded now; replay-on-create still works.
@MainActor
@Suite("Spawn tree event buffer")
internal struct SpawnTreeStoreBufferTests {

    private func makeStore() -> SpawnTreeStore {
        SpawnTreeStore(batchHistory: DelegationBatchHistoryStore(testing: true))
    }

    private func toolStart(_ index: Int) -> GatewayEvent {
        .toolStart(payload: ToolStartPayload(toolID: "t\(index)", name: "bash", context: "ls \(index)"))
    }

    @Test("a tree-less session keeps at most a bounded tail of events")
    internal func perSessionBound() {
        let store = makeStore()
        for index in 0..<400 {
            store.ingest(toolStart(index), sessionID: "unwatched")
        }
        #expect(store.bufferedEventCount(for: "unwatched") == 256)
    }

    @Test("the number of buffered sessions is bounded, oldest evicted first")
    internal func sessionCountBound() {
        let store = makeStore()
        for session in 0..<40 {
            store.ingest(toolStart(session), sessionID: "s\(session)")
        }
        #expect(store.bufferedSessionCount == 32)
        #expect(store.bufferedEventCount(for: "s0") == 0)
        #expect(store.bufferedEventCount(for: "s39") == 1)
    }

    @Test("events buffered before a tree exists replay into it on creation")
    internal func replayOnCreate() {
        let store = makeStore()
        for index in 0..<3 {
            store.ingest(toolStart(index), sessionID: "fresh")
        }
        store.createTree(sessionID: "fresh", prompt: "do the thing")
        #expect(store.sessions.first?.root.toolCalls.count == 3)
        #expect(store.bufferedEventCount(for: "fresh") == 0)
        #expect(store.bufferedSessionCount == 0)
    }
}
