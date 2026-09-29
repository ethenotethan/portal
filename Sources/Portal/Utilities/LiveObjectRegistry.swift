import Foundation
import ObjectiveC

// MARK: - Live-object registry

/// How many instances of each kind of interesting object are alive right now,
/// and the most that ever were. Counting only: `register`/`unregister` in an
/// init/deinit pair, or `track(_:as:)` to attach a sentinel whose deinit does
/// the unregister for objects whose type we do not own (a `WKWebView`).
///
/// The session health monitor samples this every cycle, so a leak — a kind
/// whose count only ever climbs across a long session — is visible in the log
/// before it becomes a beachball. Thread-safe; never throws; never blocks a
/// caller beyond one lock hand-off.
internal final class LiveObjectRegistry: @unchecked Sendable {
    internal struct Snapshot: Codable, Equatable, Sendable {
        internal var counts: [String: Int]
        internal var peaks: [String: Int]

        internal func count(_ kind: String) -> Int { counts[kind] ?? 0 }
        internal func peak(_ kind: String) -> Int { peaks[kind] ?? 0 }
    }

    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var peaks: [String: Int] = [:]

    internal init() {}

    internal func register(_ kind: String) {
        lock.lock()
        let next = (counts[kind] ?? 0) + 1
        counts[kind] = next
        if next > (peaks[kind] ?? 0) { peaks[kind] = next }
        lock.unlock()
    }

    internal func unregister(_ kind: String) {
        lock.lock()
        counts[kind] = max(0, (counts[kind] ?? 0) - 1)
        lock.unlock()
    }

    /// Registers `kind` now and unregisters it when `object` deallocates, via an
    /// associated sentinel — so a framework object is counted without a subclass.
    internal func track(_ object: AnyObject, as kind: String) {
        register(kind)
        let sentinel = LiveObjectSentinel { [weak self] in self?.unregister(kind) }
        objc_setAssociatedObject(object, &LiveObjectRegistry.sentinelKey, sentinel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    internal func count(_ kind: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[kind] ?? 0
    }

    internal func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(counts: counts.filter { $0.value > 0 }, peaks: peaks)
    }

    // Only the address is used as the associated-object key.
    nonisolated(unsafe) private static var sentinelKey: UInt8 = 0
}

/// Fires its closure when the object it is attached to deallocates.
private final class LiveObjectSentinel {
    private let onDeinit: () -> Void

    init(onDeinit: @escaping () -> Void) {
        self.onDeinit = onDeinit
    }

    deinit {
        onDeinit()
    }
}

/// The kinds the monitor reports by name. Strings, so a new kind needs no
/// enum case; these constants keep the spelling in one place.
internal enum LiveObjectKind {
    internal static let chatViewModel = "ChatViewModel"
    internal static let webView = "WKWebView"
    internal static let inlineHTMLView = "InlineHTMLView"
    internal static let artifactCanvas = "ArtifactCanvas"
}

// MARK: - Monotonic health counters

/// Cheap "how many times did X happen" counters the health sample reports as
/// per-interval deltas: artifact relayouts, web-view reloads, gateway events.
/// Monotonic and thread-safe; the monitor diffs consecutive snapshots.
internal final class HealthCounters: @unchecked Sendable {
    internal struct Snapshot: Codable, Equatable, Sendable {
        internal var values: [String: Int]

        internal func value(_ name: String) -> Int { values[name] ?? 0 }

        /// Per-name growth since `earlier` (names absent there count from zero).
        internal func delta(since earlier: Snapshot?) -> [String: Int] {
            var out: [String: Int] = [:]
            for (name, value) in values {
                out[name] = value - (earlier?.values[name] ?? 0)
            }
            return out
        }
    }

    private let lock = NSLock()
    private var values: [String: Int] = [:]

    internal init() {}

    internal func increment(_ name: String, by amount: Int = 1) {
        lock.lock()
        values[name, default: 0] += amount
        lock.unlock()
    }

    internal func value(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[name] ?? 0
    }

    internal func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(values: values)
    }
}

/// The counter names the health line reports.
internal enum HealthCounter {
    internal static let artifactRelayouts = "artifact.relayouts"
    internal static let webViewReloads = "webview.reloads"
    internal static let gatewayEvents = "gateway.events"
    /// Prefix; the RPC method is appended (`gateway.rpc.timeouts.cron.graph`).
    internal static let rpcTimeouts = "gateway.rpc.timeouts"
    internal static let rpcLateResponses = "gateway.rpc.lateResponses"
    internal static let rpcDroppedByDisconnect = "gateway.rpc.droppedByDisconnect"
    internal static let artifactQueryCoalesced = "artifact.query.coalesced"
}

/// Process-wide instances as module-level constants (the repository's
/// no-singletons rule: nothing new hangs off a static accessor); tests construct
/// their own.
internal let liveObjects = LiveObjectRegistry()
internal let healthCounters = HealthCounters()
