import Foundation

/// Bounded memo for pure parse/layout results keyed by their source input.
/// SwiftUI re-runs `body` on every state change, so anything expensive
/// computed there (force-directed layouts, JSON parses, projections) must be
/// cached or it re-runs per frame — the wiki graph's choppiness (per-frame
/// radii) and the artifact pane's lag (per-render 300-iteration force sims)
/// were both this bug. FIFO eviction; thread-safe.
final class RenderMemo<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Value] = [:]
    private var order: [String] = []
    private let limit: Int

    init(limit: Int = 24) {
        self.limit = limit
    }

    func value(for key: String, compute: () -> Value) -> Value {
        lock.lock()
        if let cached = store[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let computed = compute()

        lock.lock()
        if store[key] == nil {
            store[key] = computed
            order.append(key)
            if order.count > limit {
                store.removeValue(forKey: order.removeFirst())
            }
        }
        lock.unlock()
        return computed
    }
}
