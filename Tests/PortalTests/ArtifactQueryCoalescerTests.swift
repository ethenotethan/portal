import Foundation
import Testing
@testable import Portal

@Suite("Artifact query coalescer")
internal struct ArtifactQueryCoalescerTests {
    private struct Key: Hashable, Sendable {
        let artifact: String
        let query: String
    }

    private let a = Key(artifact: "a", query: "q")
    private let b = Key(artifact: "b", query: "q")

    @Test("the first request for a key starts a fetch")
    internal func firstRequestFetches() {
        var c = ArtifactQueryCoalescer<Key>()
        let starts = c.requestFetch(a)
        #expect(starts)
        #expect(c.isInFlight(a))
        #expect(c.coalescedCount == 0)
    }

    @Test("requests during a fetch are absorbed and trigger exactly one follow-up")
    internal func dirtyRefetchesOnce() {
        var c = ArtifactQueryCoalescer<Key>()
        let first = c.requestFetch(a)
        let second = c.requestFetch(a)
        let third = c.requestFetch(a)
        let fourth = c.requestFetch(a)
        #expect(first)
        #expect(!second && !third && !fourth)
        #expect(c.coalescedCount == 3)
        #expect(c.isInFlight(a))

        // First fetch lands: dirty → fetch once more, still in flight.
        let refetch = c.finished(a)
        #expect(refetch)
        #expect(c.isInFlight(a))
        #expect(c.dirty.isEmpty)
        // Follow-up lands with nothing new: idle.
        let again = c.finished(a)
        #expect(!again)
        #expect(!c.isInFlight(a))
    }

    @Test("a quiet fetch leaves the key idle and the next request fetches again")
    internal func quietFetchGoesIdle() {
        var c = ArtifactQueryCoalescer<Key>()
        let first = c.requestFetch(a)
        let refetch = c.finished(a)
        let next = c.requestFetch(a)
        #expect(first)
        #expect(!refetch)
        #expect(next)
    }

    @Test("keys are independent")
    internal func keysIndependent() {
        var c = ArtifactQueryCoalescer<Key>()
        let startA = c.requestFetch(a)
        let startB = c.requestFetch(b)
        let repeatA = c.requestFetch(a)
        let refetchB = c.finished(b)
        let refetchA = c.finished(a)
        #expect(startA && startB)
        #expect(!repeatA)
        #expect(!refetchB)
        #expect(refetchA)
        #expect(c.isInFlight(a))
        #expect(!c.isInFlight(b))
    }

    @Test("release forgets in-flight and dirty state for one key")
    internal func releaseForgetsKey() {
        var c = ArtifactQueryCoalescer<Key>()
        _ = c.requestFetch(a)
        _ = c.requestFetch(a)
        c.release(a)
        #expect(!c.isInFlight(a))
        #expect(c.dirty.isEmpty)
        let refetch = c.finished(a)
        let next = c.requestFetch(a)
        #expect(!refetch)
        #expect(next)
    }

    @Test("releaseAll drops every key matching the predicate and no other")
    internal func releaseAllByPredicate() {
        var c = ArtifactQueryCoalescer<Key>()
        _ = c.requestFetch(a)
        _ = c.requestFetch(a)
        _ = c.requestFetch(b)
        _ = c.requestFetch(b)
        c.releaseAll { $0.artifact == "a" && $0.query == "q" }
        #expect(!c.isInFlight(a))
        #expect(c.isInFlight(b))
        #expect(c.dirty == [b])
    }
}
