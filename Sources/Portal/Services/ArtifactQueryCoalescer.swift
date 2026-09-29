import Foundation

/// Collapses bursts of "re-fetch this" requests into at most one fetch in flight
/// per key, plus at most one follow-up.
///
/// The gateway emits `artifact.query.changed` for every subscribed query whose
/// data moved, and on a busy harness several such events for the same slot can
/// arrive while the previous `artifact.query.invoke` is still queued behind
/// other traffic. Re-running the query for each event stacked invokes on the
/// serial connection (≈1,280/day measured). Instead: a request for a key with
/// no fetch outstanding starts one; a request while one is outstanding only
/// marks the key dirty; when the fetch completes, a dirty key is fetched once
/// more — so N events during one fetch cost exactly two fetches, and the second
/// sees the newest data.
///
/// Pure state; the caller owns the fetch tasks. Tallies `artifact.query.coalesced`
/// (`PerfCounter` in the instrumented harness, `healthCounters` at runtime).
internal struct ArtifactQueryCoalescer<Key: Hashable & Sendable>: Sendable {
    internal private(set) var inFlight: Set<Key> = []
    internal private(set) var dirty: Set<Key> = []
    /// Requests absorbed into an already in-flight fetch since construction.
    internal private(set) var coalescedCount = 0

    /// A fetch for `key` was requested. Returns true when the caller should start
    /// one now; false when one is already outstanding and the key is now dirty.
    internal mutating func requestFetch(_ key: Key) -> Bool {
        if inFlight.contains(key) {
            dirty.insert(key)
            coalescedCount += 1
            PerfCounter.tick(HealthCounter.artifactQueryCoalesced)
            healthCounters.increment(HealthCounter.artifactQueryCoalesced)
            return false
        }
        inFlight.insert(key)
        return true
    }

    /// The fetch for `key` completed. Returns true when a request arrived during
    /// it and the caller should fetch once more (the key stays in flight);
    /// false when the key is now idle.
    internal mutating func finished(_ key: Key) -> Bool {
        if dirty.remove(key) != nil {
            return true
        }
        inFlight.remove(key)
        return false
    }

    /// Forget `key` entirely (its page went away or its task was cancelled).
    internal mutating func release(_ key: Key) {
        inFlight.remove(key)
        dirty.remove(key)
    }

    /// Forget every key matching `predicate`.
    internal mutating func releaseAll(where predicate: (Key) -> Bool) {
        inFlight = inFlight.filter { !predicate($0) }
        dirty = dirty.filter { !predicate($0) }
    }

    internal func isInFlight(_ key: Key) -> Bool { inFlight.contains(key) }
}
