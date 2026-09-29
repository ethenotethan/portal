import Foundation
import Testing
@testable import Portal

@Suite("Gateway poll policy")
internal struct GatewayPollPolicyTests {
    private func policy(base: TimeInterval = 60, cap: TimeInterval = 600, slow: TimeInterval = 5) -> GatewayPollPolicy {
        GatewayPollPolicy(
            method: "cron.graph",
            configuration: GatewayPollPolicy.Configuration(baseInterval: base, maxInterval: cap, slowThreshold: slow)
        )
    }

    /// One allowed tick that completed in `elapsed` seconds.
    private func cycle(_ p: inout GatewayPollPolicy, elapsed: TimeInterval, succeeded: Bool = true) {
        _ = p.decide(visible: true, connected: true)
        p.finished(elapsed: elapsed, succeeded: succeeded)
    }

    @Test("starts at the base interval with nothing in flight")
    internal func initialState() {
        let p = policy()
        #expect(p.interval == 60)
        #expect(!p.inFlight)
        #expect(p.skips.isEmpty)
        #expect(p.backoffCount == 0)
    }

    @Test("a visible, connected tick fires and marks the call in flight")
    internal func firesWhenAllowed() {
        var p = policy()
        let skip = p.decide(visible: true, connected: true)
        #expect(skip == nil)
        #expect(p.inFlight)
    }

    @Test("a tick while the previous call is outstanding is skipped, not stacked")
    internal func skipsWhileInFlight() {
        var p = policy()
        _ = p.decide(visible: true, connected: true)
        let first = p.decide(visible: true, connected: true)
        let second = p.decide(visible: true, connected: true)
        #expect(first == .inFlight)
        #expect(second == .inFlight)
        #expect(p.skips[.inFlight] == 2)
        p.finished(elapsed: 1, succeeded: true)
        let afterLanding = p.decide(visible: true, connected: true)
        #expect(afterLanding == nil)
    }

    @Test("no surface showing: skipped, and hidden outranks every other reason")
    internal func skipsWhenHidden() {
        var p = policy()
        _ = p.decide(visible: true, connected: true)
        let skip = p.decide(visible: false, connected: false)
        #expect(skip == .hidden)
        #expect(p.skips[.hidden] == 1)
        #expect(p.skips[.reconnecting] == nil)
        #expect(p.skips[.inFlight] == nil)
    }

    @Test("reconnecting: skipped without touching the interval")
    internal func skipsWhileReconnecting() {
        var p = policy()
        let skip = p.decide(visible: true, connected: false)
        #expect(skip == .reconnecting)
        #expect(p.skips[.reconnecting] == 1)
        #expect(!p.inFlight)
        #expect(p.interval == 60)
    }

    @Test("a slow success doubles the interval; a fast success resets it")
    internal func slowDoublesFastResets() {
        var p = policy()
        cycle(&p, elapsed: 12)
        #expect(p.interval == 120)
        #expect(p.backoffCount == 1)
        #expect(!p.inFlight)

        cycle(&p, elapsed: 7)
        #expect(p.interval == 240)
        #expect(p.backoffCount == 2)

        cycle(&p, elapsed: 0.8)
        #expect(p.interval == 60)
        #expect(p.backoffCount == 0)
    }

    @Test("exactly the threshold still counts as fast")
    internal func thresholdIsInclusive() {
        var p = policy()
        cycle(&p, elapsed: 5)
        #expect(p.interval == 60)
    }

    @Test("a failed or dropped call doubles even when it returned quickly")
    internal func failureDoubles() {
        var p = policy()
        cycle(&p, elapsed: 0.1, succeeded: false)
        #expect(p.interval == 120)
        #expect(!p.inFlight)
    }

    @Test("doubling stops at the cap")
    internal func capsAtMaximum() {
        var p = policy()
        for _ in 0..<8 {
            cycle(&p, elapsed: 30, succeeded: false)
        }
        #expect(p.interval == 600)
        #expect(p.backoffCount == 8)
        cycle(&p, elapsed: 1)
        #expect(p.interval == 60)
    }

    @Test("a late response after a timeout backs off like a slow call")
    internal func lateResponseBacksOff() {
        var p = policy()
        p.noteLateResponse()
        #expect(p.interval == 120)
        p.noteLateResponse()
        #expect(p.interval == 240)
        // It carries no in-flight state of its own.
        #expect(!p.inFlight)
    }

    @Test("configuration is honoured for base, cap and threshold")
    internal func customConfiguration() {
        var p = policy(base: 10, cap: 25, slow: 2)
        #expect(p.interval == 10)
        cycle(&p, elapsed: 3)
        #expect(p.interval == 20)
        cycle(&p, elapsed: 3)
        #expect(p.interval == 25)
        cycle(&p, elapsed: 2)
        #expect(p.interval == 10)
    }
}

@MainActor
@Suite("Cron surface interest")
internal struct CronSurfaceInterestTests {
    @Test("counts balanced appear/disappear pairs and never goes negative")
    internal func referenceCounting() {
        let interest = CronSurfaceInterest()
        #expect(!interest.isVisible)
        interest.surfaceAppeared()
        interest.surfaceAppeared()
        #expect(interest.visibleCount == 2)
        interest.surfaceDisappeared()
        #expect(interest.isVisible)
        interest.surfaceDisappeared()
        #expect(!interest.isVisible)
        interest.surfaceDisappeared()
        #expect(interest.visibleCount == 0)
        interest.surfaceAppeared()
        #expect(interest.isVisible)
    }
}
