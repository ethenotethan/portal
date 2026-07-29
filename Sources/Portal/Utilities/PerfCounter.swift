import Foundation

/// Algorithmic work counter for the performance ratchet.
///
/// The perf ratchet tracks *how much work* the hot pure layout paths do —
/// iteration counts, not wall-clock time. A machine-independent op count is
/// deterministic (same on any runner, no flaky timing) and catches the
/// regression that actually hurts: an O(n) path quietly becoming O(n²). It
/// does NOT catch constant-factor slowdowns — that's what the hang gate and
/// timing profiles are for. See docs/architecture-rules.md ("Performance").
///
/// ## Zero cost when off
/// Every counter call is gated on the `PERF_COUNTERS` compile flag. A normal
/// build (`swift build`, `make build`, the shipped app) never defines it, so
/// `tick`/`add` compile to an `@inline(__always)` empty body the optimizer
/// deletes outright — the instrumentation does not exist in production. Only
/// the Performance CI job and `make perf-ratchet` build with
/// `-Xswiftc -DPERF_COUNTERS`, which activates the tallies for the harness
/// test that reads them back via `snapshot()`.
///
/// Because the instrumented paths (`SankeyLayout`, `NetworkGraphLayout`) are
/// `nonisolated` static functions callable off the main actor, the store is
/// lock-guarded. That lock only exists in the instrumented build.
internal enum PerfCounter {
    #if PERF_COUNTERS
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()

    /// Add `n` units of work under `key`. Called once per loop with the loop's
    /// accumulated count — never once per iteration — so even the instrumented
    /// build doesn't pay a locked call inside a hot loop.
    internal static func add(_ key: String, _ n: Int) {
        lock.lock()
        counts[key, default: 0] += n
        lock.unlock()
    }

    /// Increment `key` by one (for one-shot events, not hot loops).
    internal static func tick(_ key: String) { add(key, 1) }

    /// Clear all tallies. The harness calls this before each scenario so the
    /// snapshot reflects exactly one layout run.
    internal static func reset() {
        lock.lock()
        counts = [:]
        lock.unlock()
    }

    /// Current tallies, copied out under the lock.
    internal static func snapshot() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return counts
    }
    #else
    @inline(__always) internal static func add(_ key: String, _ n: Int) {}
    @inline(__always) internal static func tick(_ key: String) {}
    @inline(__always) internal static func reset() {}
    @inline(__always) internal static func snapshot() -> [String: Int] { [:] }
    #endif
}
