import Combine
import Foundation
import Testing
@testable import Portal

@MainActor
@Suite("Cron poller")
internal struct CronPollerTests {
    /// A gateway stand-in: answers `cron.graph` / `cron.manage list` from a
    /// script, reports whether it is connected, and lets a test hold a call open.
    private final class FakeSource: CronPollSource {
        var isPollable = true
        let signals = PassthroughSubject<CronPollSignal, Never>()
        var pollSignals: AnyPublisher<CronPollSignal, Never> { signals.eraseToAnyPublisher() }

        var graphCalls = 0
        var jobsCalls = 0
        var graphError: Error?
        /// When set, `cronGraph` parks until `releaseGraph()`.
        var holdGraph = false
        private var held: [CheckedContinuation<Void, Never>] = []
        /// Advanced by the test clock while a call is "running".
        var clock: TestClock

        init(clock: TestClock) { self.clock = clock }

        func cronGraph() async throws -> CronGraph {
            graphCalls += 1
            if holdGraph {
                await withCheckedContinuation { held.append($0) }
            }
            clock.advance(by: clock.graphDuration)
            if let graphError { throw graphError }
            return CronGraph(
                nodes: [
                    CronGraphNode(
                        id: "job", kind: "cron", type: "cron", label: "job", description: "",
                        schedule: "every 1h", enabled: true, usesLLM: false, lastStatus: "ok", deliver: nil
                    ),
                ],
                edges: []
            )
        }

        func listCronJobs() async throws -> [CronJob] {
            jobsCalls += 1
            // An id no artifact's `updatedBy` can contain, so the maintainer
            // stamp iterates the shared store without ever writing to it.
            return [
                CronJob(
                    id: "poller-test-\(UUID().uuidString)", name: "Poller test", schedule: "every 1h",
                    nextRunAt: nil, lastRunAt: nil, lastStatus: nil, enabled: true, state: "scheduled",
                    deliver: "local", promptPreview: nil, prompt: nil, lastError: nil
                ),
            ]
        }

        func releaseGraph() {
            let waiting = held
            held = []
            for continuation in waiting { continuation.resume() }
        }
    }

    /// Deterministic time for the poller's elapsed measurement.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var now = Date(timeIntervalSince1970: 1_000)
        var graphDuration: TimeInterval = 1

        func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return now
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            now = now.addingTimeInterval(seconds)
            lock.unlock()
        }
    }

    /// Records every sleep the loops request and never wakes on its own, so a
    /// test drives each subsequent tick explicitly (visibility flip, reconnect).
    private final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [TimeInterval] = []

        var recorded: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return waits
        }

        private func record(_ seconds: TimeInterval) {
            lock.lock()
            waits.append(seconds)
            lock.unlock()
        }

        @Sendable func sleep(_ seconds: TimeInterval) async throws {
            record(seconds)
            try await Task.sleep(for: .seconds(3_600))
        }
    }

    private struct Harness {
        let store: CronGraphStore
        let interest: CronSurfaceInterest
        let source: FakeSource
        let clock: TestClock
        let sleeps: SleepLog
        let poller: CronPoller
    }

    private func makeHarness(configuration: GatewayPollPolicy.Configuration = GatewayPollPolicy.Configuration()) -> Harness {
        let clock = TestClock()
        let sleeps = SleepLog()
        let interest = CronSurfaceInterest()
        let store = CronGraphStore(revisionStore: CronGraphRevisionStore(testing: true))
        let poller = CronPoller(
            graphStore: store, interest: interest, configuration: configuration,
            sleep: sleeps.sleep, now: { clock.read() }
        )
        return Harness(store: store, interest: interest, source: FakeSource(clock: clock), clock: clock, sleeps: sleeps, poller: poller)
    }

    /// Let the poller's detached loop tasks run up to their first sleep.
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test("no cron surface on screen: adopting a gateway issues no calls")
    internal func hiddenIssuesNothing() async {
        let h = makeHarness()
        h.poller.setSource(h.source)
        await settle()
        #expect(h.source.graphCalls == 0)
        #expect(h.source.jobsCalls == 0)
        #expect(h.sleeps.recorded.isEmpty)
    }

    @Test("first surface appearing refreshes both methods once and schedules the base interval")
    internal func appearanceRefreshesOnce() async {
        let h = makeHarness()
        h.poller.setSource(h.source)
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 1)
        #expect(h.source.jobsCalls == 1)
        #expect(h.store.graph.nodes.map(\.id) == ["job"])
        #expect(h.sleeps.recorded == [60, 60])
        #expect(h.poller.graphPolicy.interval == 60)
        #expect(h.poller.jobsPolicy.interval == 60)
    }

    @Test("a second surface on top of the first does not refresh again; the last one leaving stops the loops")
    internal func referenceCountedVisibility() async {
        let h = makeHarness()
        h.poller.setSource(h.source)
        h.interest.surfaceAppeared()
        await settle()
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 1)

        h.interest.surfaceDisappeared()
        await settle()
        #expect(h.source.graphCalls == 1)
        h.interest.surfaceDisappeared()
        await settle()
        // Hidden: nothing new is fetched even when time passes.
        #expect(h.source.graphCalls == 1)
        #expect(h.source.jobsCalls == 1)

        // Re-appearing refreshes once more.
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 2)
        #expect(h.source.jobsCalls == 2)
    }

    @Test("a slow cron.graph doubles only that method's interval; a fast one resets it")
    internal func slowGraphBacksOffIndependently() async {
        let h = makeHarness()
        h.clock.graphDuration = 12
        h.poller.setSource(h.source)
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.poller.graphPolicy.interval == 120)
        #expect(h.poller.jobsPolicy.interval == 60)
        #expect(h.sleeps.recorded.sorted() == [60, 120])

        h.clock.graphDuration = 1
        h.interest.surfaceDisappeared()
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 2)
        #expect(h.poller.graphPolicy.interval == 60)
    }

    @Test("a failed cron.graph keeps the cached graph and backs off")
    internal func failureBacksOff() async {
        let h = makeHarness()
        h.source.graphError = GatewayError.disconnected
        h.poller.setSource(h.source)
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 1)
        #expect(h.store.graph.nodes.isEmpty)
        #expect(h.poller.graphPolicy.interval == 120)
        #expect(h.poller.graphPolicy.backoffCount == 1)
    }

    @Test("while the gateway is reconnecting no call is issued; .connected polls immediately")
    internal func reconnectingSkipsThenResumes() async {
        let h = makeHarness()
        h.source.isPollable = false
        h.poller.setSource(h.source)
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 0)
        #expect(h.source.jobsCalls == 0)
        #expect(h.poller.graphPolicy.skips[.reconnecting] == 1)
        #expect(h.poller.jobsPolicy.skips[.reconnecting] == 1)
        // Skipping does not back off: the socket, not the gateway, was the problem.
        #expect(h.poller.graphPolicy.interval == 60)

        h.source.isPollable = true
        h.source.signals.send(.connected)
        await settle()
        #expect(h.source.graphCalls == 1)
        #expect(h.source.jobsCalls == 1)
    }

    @Test(".connected while hidden does not poll")
    internal func connectedWhileHiddenStaysQuiet() async {
        let h = makeHarness()
        h.poller.setSource(h.source)
        h.source.signals.send(.connected)
        await settle()
        #expect(h.source.graphCalls == 0)
    }

    @Test("a tick while the previous cron.graph is still outstanding is skipped, not stacked")
    internal func inFlightSkipsTick() async {
        let h = makeHarness()
        h.source.holdGraph = true
        h.poller.setSource(h.source)
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 1)
        #expect(h.poller.graphPolicy.inFlight)

        // Force another tick (surface flip) while the first call is parked.
        h.interest.surfaceDisappeared()
        h.interest.surfaceAppeared()
        await settle()
        #expect(h.source.graphCalls == 1)
        #expect(h.poller.graphPolicy.skips[.inFlight] == 1)
        // The jobs call was not held, so its tick did fire again.
        #expect(h.source.jobsCalls == 2)

        h.source.holdGraph = false
        h.source.releaseGraph()
        await settle()
        #expect(!h.poller.graphPolicy.inFlight)
    }

    @Test("a late cron.graph response backs off the graph schedule only")
    internal func lateResponseBacksOff() async {
        let h = makeHarness()
        h.poller.setSource(h.source)
        h.source.signals.send(.lateResponse(method: "cron.graph"))
        h.source.signals.send(.lateResponse(method: "session.list"))
        await settle()
        #expect(h.poller.graphPolicy.interval == 120)
        #expect(h.poller.jobsPolicy.interval == 60)
    }

    @Test("adopting the same gateway twice is a no-op")
    internal func sameSourceIgnored() async {
        let h = makeHarness()
        h.interest.surfaceAppeared()
        h.poller.setSource(h.source)
        await settle()
        h.poller.setSource(h.source)
        await settle()
        #expect(h.source.graphCalls == 1)
    }

    @Test("a real GatewayClient can be adopted while hidden without issuing anything")
    internal func adoptsGatewayClient() async {
        let h = makeHarness()
        h.poller.setGatewayClient(GatewayClient())
        await settle()
        #expect(h.sleeps.recorded.isEmpty)
        #expect(h.poller.graphPolicy.interval == 60)
    }

    @Test("GatewayClient reports pollable only while connected")
    internal func gatewayClientPollable() {
        let client = GatewayClient()
        #expect(!client.isPollable)
        client.connectionState = .connected
        #expect(client.isPollable)
        client.connectionState = .reconnecting(attempt: 1)
        #expect(!client.isPollable)
    }

    @Test("GatewayClient signals .connected transitions and late responses")
    internal func gatewayClientSignals() async {
        let client = GatewayClient()
        var received: [CronPollSignal] = []
        let cancellable = client.pollSignals.sink { received.append($0) }
        client.connectionState = .connecting
        client.connectionState = .connected
        client.lateResponses.send("cron.graph")
        client.connectionState = .reconnecting(attempt: 1)
        #expect(received == [.connected, .lateResponse(method: "cron.graph")])
        cancellable.cancel()
    }
}

@MainActor
@Suite("Gateway client late responses")
internal struct GatewayClientLateResponseTests {
    private func response(id: Int) -> JSONRPCResponse {
        JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: nil)
    }

    @Test("a response to a timed-out request is attributed by method and published")
    internal func lateResponseAttributed() {
        let client = GatewayClient()
        var late: [String] = []
        let cancellable = client.lateResponses.sink { late.append($0) }
        client.rememberTimedOutForTesting(id: 7, method: "cron.graph")
        client.deliverResponseForTesting(id: 7, response: response(id: 7))
        #expect(late == ["cron.graph"])
        // Attributed once: a duplicate response for the same id is just unknown.
        client.deliverResponseForTesting(id: 7, response: response(id: 7))
        #expect(late == ["cron.graph"])
        cancellable.cancel()
    }

    @Test("an unknown response id is neither attributed nor published")
    internal func unknownResponseIgnored() {
        let client = GatewayClient()
        var late: [String] = []
        let cancellable = client.lateResponses.sink { late.append($0) }
        client.deliverResponseForTesting(id: 99, response: response(id: 99))
        #expect(late.isEmpty)
        cancellable.cancel()
    }

    @Test("the timed-out memory is bounded, evicting the oldest ids first")
    internal func timedOutMemoryBounded() {
        let client = GatewayClient()
        var late: [String] = []
        let cancellable = client.lateResponses.sink { late.append($0) }
        for id in 1...70 {
            client.rememberTimedOutForTesting(id: id, method: "session.list")
        }
        client.deliverResponseForTesting(id: 1, response: response(id: 1))
        #expect(late.isEmpty, "id 1 was evicted once the memory exceeded 64 entries")
        client.deliverResponseForTesting(id: 70, response: response(id: 70))
        #expect(late == ["session.list"])
        cancellable.cancel()
    }

    @Test("a disconnect with nothing pending fails nothing and does not crash")
    internal func disconnectWithNothingPending() {
        let client = GatewayClient()
        client.handleDisconnectForTesting(reason: "test")
        #expect(healthCounters.value(HealthCounter.rpcDroppedByDisconnect) >= 0)
    }
}
