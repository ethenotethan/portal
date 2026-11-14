import Combine
import Foundation

private let log = PortalLogger(category: "CronPoller")

/// Connection-level facts the poller schedules against.
internal enum CronPollSignal: Sendable, Equatable {
    /// The socket (re)opened: poll now if a surface is showing.
    case connected
    /// A response to `method` arrived after the client had timed the call out.
    case lateResponse(method: String)
}

/// What `CronPoller` needs from a gateway: the two cron reads, whether a call
/// can be issued right now, and the signals that re-time the schedule.
@MainActor
internal protocol CronPollSource: CronGraphFetching {
    /// True only while the socket is open — never during a reconnect backoff.
    var isPollable: Bool { get }
    var pollSignals: AnyPublisher<CronPollSignal, Never> { get }
    func listCronJobs() async throws -> [CronJob]
}

extension GatewayClient: CronPollSource {
    internal var isPollable: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    internal var pollSignals: AnyPublisher<CronPollSignal, Never> {
        let connects = $connectionState.compactMap { state -> CronPollSignal? in
            if case .connected = state { return .connected }
            return nil
        }
        let late = lateResponses.map { CronPollSignal.lateResponse(method: $0) }
        return connects.merge(with: late).eraseToAnyPublisher()
    }
}

/// Keeps cron state fresh for whichever cron surface is on screen.
///
/// Two independent schedules — `cron.graph` (the interflow graph) and
/// `cron.manage list` (job rows → `CronRunHistoryStore.detectNewRuns` and the
/// artifact-maintainer stamp) — each governed by its own `GatewayPollPolicy`.
/// This replaced a fixed `Timer.scheduledTimer(withTimeInterval: 60)` that
/// fired both calls all day regardless of what was visible; on a slow gateway
/// those ~1,000 serial calls/day queued the user's own actions behind them.
///
/// - Polls only while `CronSurfaceInterest.isVisible`; going 0 → 1 refreshes
///   immediately, going 1 → 0 stops both loops.
/// - Never overlaps two calls of the same method (the policy skips the tick).
/// - Backs off 60 s → 10 min on slow/failed/late calls, resets on a fast one.
/// - Skips ticks while the socket is reconnecting; polls again as soon as it
///   reports `.connected`.
@MainActor
internal final class CronPoller: ObservableObject {
    internal typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    private enum Kind: CaseIterable {
        case graph
        case jobs

        var method: String {
            switch self {
            case .graph: "cron.graph"
            case .jobs: "cron.manage"
            }
        }
    }

    private weak var source: (any CronPollSource)?
    private let graphStore: CronGraphStore
    private let interest: CronSurfaceInterest
    private let sleep: Sleep
    private let now: @Sendable () -> Date

    /// Schedule for `cron.graph`.
    internal private(set) var graphPolicy: GatewayPollPolicy
    /// Schedule for `cron.manage` (action `list`).
    internal private(set) var jobsPolicy: GatewayPollPolicy

    // nonisolated(unsafe) so the nonisolated deinit can cancel them. All other
    // reads/writes happen on the MainActor; deinit runs after the last
    // (MainActor-held) reference is released.
    nonisolated(unsafe) private var loops: [Task<Void, Never>] = []
    private var interestCancellable: AnyCancellable?
    private var signalCancellable: AnyCancellable?

    internal init(
        graphStore: CronGraphStore,
        interest: CronSurfaceInterest = cronSurfaceInterest,
        configuration: GatewayPollPolicy.Configuration = GatewayPollPolicy.Configuration(),
        sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.graphStore = graphStore
        self.interest = interest
        self.sleep = sleep
        self.now = now
        graphPolicy = GatewayPollPolicy(method: Kind.graph.method, configuration: configuration)
        jobsPolicy = GatewayPollPolicy(method: Kind.jobs.method, configuration: configuration)
        LeakTracker.track(self)
        // `@Published` emits on willSet, so read the emitted value rather than
        // `interest.isVisible` here.
        interestCancellable = interest.$visibleCount
            .map { $0 > 0 }
            .removeDuplicates()
            .sink { [weak self] visible in
                self?.visibilityChanged(visible)
            }
    }

    internal func setGatewayClient(_ client: GatewayClient) {
        setSource(client)
    }

    /// Adopt a gateway. Loops (re)start only if a cron surface is showing.
    internal func setSource(_ source: any CronPollSource) {
        guard self.source !== source else { return }
        self.source = source
        signalCancellable = source.pollSignals.sink { [weak self] signal in
            self?.handle(signal)
        }
        restartLoops(visible: interest.isVisible)
    }

    private func policy(_ kind: Kind) -> GatewayPollPolicy {
        switch kind {
        case .graph: graphPolicy
        case .jobs: jobsPolicy
        }
    }

    private func updatePolicy(_ kind: Kind, _ body: (inout GatewayPollPolicy) -> Void) {
        switch kind {
        case .graph: body(&graphPolicy)
        case .jobs: body(&jobsPolicy)
        }
    }

    private func visibilityChanged(_ visible: Bool) {
        log.debug("cron surfaces \(visible ? "visible — polling" : "hidden — polling stopped")")
        restartLoops(visible: visible)
    }

    private func handle(_ signal: CronPollSignal) {
        switch signal {
        case .connected:
            // A reconnect after a hidden→visible flip may have missed the
            // appearance refresh; poll now rather than at the next tick.
            guard interest.isVisible else { return }
            restartLoops(visible: true)
        case .lateResponse(let method):
            for kind in Kind.allCases where kind.method == method {
                let before = policy(kind).interval
                updatePolicy(kind) { $0.noteLateResponse() }
                logIntervalChange(kind, from: before, detail: "late response")
            }
        }
    }

    private func restartLoops(visible: Bool) {
        stopLoops()
        guard visible, source != nil else { return }
        loops = Kind.allCases.map { kind in
            Task { [weak self] in await self?.run(kind) }
        }
    }

    private func stopLoops() {
        for loop in loops { loop.cancel() }
        loops = []
    }

    /// One method's loop: tick, then sleep for the policy's current interval.
    /// Cancellation (surface hidden, client swapped) ends it at the next await.
    private func run(_ kind: Kind) async {
        while !Task.isCancelled {
            await tick(kind)
            let wait = policy(kind).interval
            do {
                try await sleep(wait)
            } catch {
                return
            }
        }
    }

    private func tick(_ kind: Kind) async {
        guard let source else { return }
        var skip: GatewayPollPolicy.Skip?
        let visible = interest.isVisible
        let connected = source.isPollable
        updatePolicy(kind) { skip = $0.decide(visible: visible, connected: connected) }
        if let skip {
            log.debug("\(kind.method) poll skipped: \(skip.rawValue)")
            return
        }
        let started = now()
        var succeeded = true
        do {
            switch kind {
            case .graph:
                try await graphStore.refresh(from: source)
            case .jobs:
                let jobs = try await source.listCronJobs()
                CronRunHistoryStore.shared.detectNewRuns(from: jobs)
                // Auto-declare each job as a maintainer on any artifacts it wrote.
                for job in jobs {
                    Self.stampMaintainerForJob(job)
                }
            }
        } catch {
            // Best-effort background refresh: the cached state stays on screen
            // and the surface's manual reload remains the user-visible error path.
            succeeded = false
            log.info("\(kind.method) poll failed: \(error.localizedDescription)")
        }
        let elapsed = now().timeIntervalSince(started)
        let before = policy(kind).interval
        updatePolicy(kind) { $0.finished(elapsed: elapsed, succeeded: succeeded) }
        logIntervalChange(kind, from: before, detail: "took \(String(format: "%.1f", elapsed))s ok=\(succeeded)")
    }

    private func logIntervalChange(_ kind: Kind, from before: TimeInterval, detail: String) {
        let after = policy(kind).interval
        guard after != before else { return }
        log.notice("\(kind.method) poll interval \(Int(before))s → \(Int(after))s (\(detail))")
    }

    /// Stamp `cron:<jobID>` onto any artifact whose `updatedBy` matches this
    /// job's name or id. Only touches artifacts that don't already list this
    /// job as a maintainer, so repeated polls are idempotent.
    private static func stampMaintainerForJob(_ job: CronJob) {
        let ref = MaintainerRef.cron(jobID: job.id)
        let artifactStore = ArtifactStore.shared
        for artifact in artifactStore.artifacts.values {
            let by = artifact.updatedBy
            guard by.contains(job.id) || by.contains(job.name) else { continue }
            guard !artifact.maintainerRefs.contains(ref) else { continue }
            artifactStore.setMaintainers(
                artifactID: artifact.id,
                refs: artifact.maintainerRefs + [ref]
            )
        }
    }

    deinit {
        // deinit is nonisolated even on a @MainActor class; cancelling the loop
        // tasks here is safe (they hold only weak self) and stops them at their
        // next await instead of letting them sleep on after the owner is gone.
        for loop in loops { loop.cancel() }
    }
}
