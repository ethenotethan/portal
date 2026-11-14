import Combine
import Foundation

/// Decides whether — and how often — one recurring gateway RPC may fire.
///
/// The gateway answers a connection's requests strictly serially, so a fixed
/// 60 s poll that takes 12 s on a slow harness queues user actions (prompt
/// submit, session create) behind it, and a poll that overlaps its predecessor
/// makes the queue longer still. This value type holds one method's schedule:
///
/// - **Visibility**: `.hidden` — nothing on screen shows the data, so no call.
/// - **Connection**: `.reconnecting` — the socket is down or re-dialling; a call
///   would only be failed by the next `handleDisconnect`.
/// - **In flight**: `.inFlight` — the previous call of this method has not
///   returned; the tick is skipped rather than stacked behind it.
/// - **Adaptive interval**: base 60 s; doubled (capped at 10 min) after a call
///   that failed, was dropped by a disconnect, timed out, answered late, or took
///   longer than `slowThreshold`; reset to base after a fast success.
///
/// Pure and clock-free: callers pass elapsed durations in and sleep for
/// `interval` themselves, so the policy is testable to the second.
/// `PerfCounter` tallies (`gateway.poll.*`) make the schedule observable in the
/// instrumented harness; `healthCounters` carry the same names at runtime.
internal struct GatewayPollPolicy: Sendable, Equatable {
    /// Why a tick did not fire.
    internal enum Skip: String, Sendable, CaseIterable {
        case hidden
        case reconnecting
        case inFlight
    }

    internal struct Configuration: Sendable, Equatable {
        internal var baseInterval: TimeInterval = 60
        internal var maxInterval: TimeInterval = 600
        /// A call slower than this backs the schedule off even if it succeeded.
        internal var slowThreshold: TimeInterval = 5
    }

    /// The RPC method this schedule governs (counter key suffix).
    internal let method: String
    internal let configuration: Configuration
    /// Seconds to wait after a tick before the next one.
    internal private(set) var interval: TimeInterval
    /// True between `decide` returning nil and the matching `finished`.
    internal private(set) var inFlight = false
    /// How many ticks were skipped, by reason, since construction.
    internal private(set) var skips: [Skip: Int] = [:]
    /// Consecutive back-offs since the last fast success (for logging).
    internal private(set) var backoffCount = 0

    internal init(method: String, configuration: Configuration = Configuration()) {
        self.method = method
        self.configuration = configuration
        interval = configuration.baseInterval
    }

    /// Whether the tick may fire. Returns nil (and marks the call in flight)
    /// when it may; otherwise the reason it was skipped, already tallied.
    internal mutating func decide(visible: Bool, connected: Bool) -> Skip? {
        if !visible { return skip(.hidden) }
        if !connected { return skip(.reconnecting) }
        if inFlight { return skip(.inFlight) }
        inFlight = true
        PerfCounter.tick("gateway.poll.fired.\(method)")
        healthCounters.increment("gateway.poll.fired.\(method)")
        return nil
    }

    /// The in-flight call returned. A slow or failed call doubles the interval;
    /// a fast success resets it to base.
    internal mutating func finished(elapsed: TimeInterval, succeeded: Bool) {
        inFlight = false
        if succeeded && elapsed <= configuration.slowThreshold {
            resetInterval()
        } else {
            backOff(reason: succeeded ? "slow" : "failed")
        }
    }

    /// The gateway answered this method after the client had already timed the
    /// call out — the same "too slow" signal as a long `elapsed`.
    internal mutating func noteLateResponse() {
        backOff(reason: "late")
    }

    private mutating func skip(_ reason: Skip) -> Skip {
        skips[reason, default: 0] += 1
        PerfCounter.tick("gateway.poll.skip.\(reason.rawValue)")
        healthCounters.increment("gateway.poll.skip.\(reason.rawValue)")
        return reason
    }

    private mutating func backOff(reason: String) {
        interval = min(interval * 2, configuration.maxInterval)
        backoffCount += 1
        PerfCounter.tick("gateway.poll.backoff.\(reason)")
        healthCounters.increment("gateway.poll.backoff.\(method)")
    }

    private mutating func resetInterval() {
        interval = configuration.baseInterval
        backoffCount = 0
    }
}

/// Reference count of on-screen surfaces that show cron state (job list,
/// dashboard, runtime dataflow graph). `CronPoller` polls only while it is
/// non-zero and refreshes once when it goes from zero to one, so a user who
/// never opens a cron surface costs the gateway no `cron.*` calls at all.
///
/// Views register through `View.cronSurfaceVisible()`; `onAppear` and
/// `onDisappear` are balanced, so a pushed detail replacing its list keeps the
/// count at one rather than dropping to zero between the two.
@MainActor
internal final class CronSurfaceInterest: ObservableObject {
    @Published internal private(set) var visibleCount = 0

    internal init() {}

    internal var isVisible: Bool { visibleCount > 0 }

    internal func surfaceAppeared() {
        visibleCount += 1
    }

    internal func surfaceDisappeared() {
        // A disappear without a matching appear (a view torn down before its
        // onAppear ran) must not drive the count negative and pin "hidden".
        visibleCount = max(0, visibleCount - 1)
    }
}

/// Process-wide instance as a module-level constant (the repository's
/// no-singletons rule — nothing hangs off a static `.shared`); `CronPoller`
/// takes it through its initializer so tests construct their own.
@MainActor internal let cronSurfaceInterest = CronSurfaceInterest()
