import Combine
import Foundation

private let healthLog = PortalLogger(category: "Health")

/// What the main actor knows that the health sample wants: the gateway's state
/// and pool, the open sessions, the artifacts in memory. Read in one hop per
/// sample and carried across as plain values.
internal struct SessionHealthMainActorReading: Sendable {
    internal var gatewayState: String?
    internal var pendingRequests: Int?
    internal var reconnectAttempt: Int?
    internal var lastRTTms: Int?
    internal var gatewaySnapshot: GatewayDiagnosticSnapshot?
    internal var sessionsOpen: Int?
    internal var artifactsInMemory: Int?

    internal init(gatewayState: String? = nil, pendingRequests: Int? = nil, reconnectAttempt: Int? = nil,
                  lastRTTms: Int? = nil, gatewaySnapshot: GatewayDiagnosticSnapshot? = nil,
                  sessionsOpen: Int? = nil, artifactsInMemory: Int? = nil) {
        self.gatewayState = gatewayState
        self.pendingRequests = pendingRequests
        self.reconnectAttempt = reconnectAttempt
        self.lastRTTms = lastRTTms
        self.gatewaySnapshot = gatewaySnapshot
        self.sessionsOpen = sessionsOpen
        self.artifactsInMemory = artifactsInMemory
    }
}

/// The process-level numbers, read off the main actor.
internal struct SessionHealthProcessReading: Sendable {
    internal var footprintBytes: UInt64?
    internal var threadCount: Int?
    internal var fileDescriptors: Int?
    internal var cpuPercent: Double?
    internal var hangCount: Int?
    internal var stormCount: Int?
    internal var longestHangMs: Int?

    internal init(footprintBytes: UInt64? = nil, threadCount: Int? = nil, fileDescriptors: Int? = nil, cpuPercent: Double? = nil,
                  hangCount: Int? = nil, stormCount: Int? = nil, longestHangMs: Int? = nil) {
        self.footprintBytes = footprintBytes
        self.threadCount = threadCount
        self.fileDescriptors = fileDescriptors
        self.cpuPercent = cpuPercent
        self.hangCount = hangCount
        self.stormCount = stormCount
        self.longestHangMs = longestHangMs
    }

    /// The real reading: task_info for memory, mach threads for CPU and count,
    /// `/dev/fd` for descriptors, the main-thread watchdog for hangs. Each piece
    /// fails open to `nil`.
    internal static func current() -> SessionHealthProcessReading {
        let perf = ProcessMetrics.sample()
        let fds: Int?
        do {
            fds = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        } catch {
            fds = nil // no /dev/fd on this host: reported as n/a
        }
        let stalls = MainThreadWatchdog.shared.stallStatistics()
        return SessionHealthProcessReading(
            footprintBytes: perf.footprintBytes == 0 ? nil : perf.footprintBytes,
            threadCount: perf.threadCount == 0 ? nil : perf.threadCount,
            fileDescriptors: fds,
            cpuPercent: perf.cpuPercent,
            hangCount: stalls.hangs,
            stormCount: stalls.storms,
            longestHangMs: stalls.longestMs
        )
    }
}

/// What the Settings pane shows: the latest sample, the last bundle, the interval.
@MainActor
internal final class SessionHealthStatus: ObservableObject {
    @Published internal private(set) var latest: SessionHealthSample?
    @Published internal private(set) var lastBundle: URL?
    @Published internal private(set) var lastFindings: [String] = []
    @Published internal var intervalSeconds: Int

    internal init(intervalSeconds: Int) {
        self.intervalSeconds = intervalSeconds
    }

    internal func record(sample: SessionHealthSample) { latest = sample }

    internal func record(bundle: URL, findings: [String]) {
        lastBundle = bundle
        lastFindings = findings
    }
}

/// The long-session watchdog. Every interval it takes a `SessionHealthSample`,
/// logs it as one greppable `Health:` line, keeps the last two hours of samples,
/// asks the assessor whether the process is degraded, and when it is writes a
/// diagnostic bundle (rate-limited) and tells the user. `captureNow` writes a
/// bundle on demand. Everything runs off the main actor except the one hop per
/// sample that reads main-actor state; every metric fails open.
internal final class SessionHealthMonitor: @unchecked Sendable {
    internal static let defaultIntervalSeconds = 30
    internal static let allowedIntervals = [15, 30, 60]
    internal static let intervalDefaultsKey = "portal.health.intervalSeconds"
    internal static let captureOnLaunchArgument = "--capture-diagnostics-on-launch"
    internal static let maxSamples = 240

    /// Injection points; production wiring is `HermesNativeApp.startPortalSessionHealthMonitor`.
    internal struct Dependencies: @unchecked Sendable {
        internal var registry: LiveObjectRegistry = liveObjects
        internal var counters: HealthCounters = healthCounters
        internal var readProcess: @Sendable () -> SessionHealthProcessReading = { SessionHealthProcessReading.current() }
        internal var readMainActor: @MainActor @Sendable () -> SessionHealthMainActorReading = { SessionHealthMainActorReading() }
        internal var assess: @Sendable ([SessionHealthSample], Date) -> [SessionHealthAssessor.Finding] = { SessionHealthAssessor.assess($0, now: $1) }
        internal var bundleWriter = DiagnosticBundleWriter(rootDirectory: DiagnosticBundleWriter.defaultRootDirectory())
        internal var rateLimiter = DiagnosticBundleRateLimiter()
        internal var logURL: URL? = PortalLogSink.defaultLogURL()
        internal var now: @Sendable () -> Date = { Date() }
        internal var processStart = Date()
        internal var captureOnFirstSample = ProcessInfo.processInfo.arguments.contains(SessionHealthMonitor.captureOnLaunchArgument)
        internal var onBundleWritten: @Sendable (URL, [String]) -> Void = { _, _ in }
    }

    internal let status: SessionHealthStatus
    private var dependencies: Dependencies
    private let lock = NSLock()

    /// Scoped locking, synchronous so it is callable from the async paths (an
    /// `NSLock` may not be held across a suspension; nothing here suspends).
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    private var samples: [SessionHealthSample] = []
    private var lastCounters: HealthCounters.Snapshot?
    private var rateLimiter: DiagnosticBundleRateLimiter
    private var started = false
    private var loop: Task<Void, Never>?
    private var pendingLaunchCapture: Bool

    @MainActor
    internal init(dependencies: Dependencies = Dependencies()) {
        self.dependencies = dependencies
        self.rateLimiter = dependencies.rateLimiter
        self.pendingLaunchCapture = dependencies.captureOnFirstSample
        let stored = UserDefaults.standard.integer(forKey: Self.intervalDefaultsKey)
        let interval = Self.allowedIntervals.contains(stored) ? stored : Self.defaultIntervalSeconds
        self.status = SessionHealthStatus(intervalSeconds: interval)
    }

    /// Late binding for what only exists once the App's state objects do.
    internal func attachMainActorReader(_ reader: @MainActor @Sendable @escaping () -> SessionHealthMainActorReading) {
        lock.lock()
        dependencies.readMainActor = reader
        lock.unlock()
    }

    internal func setBundleHandler(_ handler: @Sendable @escaping (URL, [String]) -> Void) {
        lock.lock()
        dependencies.onBundleWritten = handler
        lock.unlock()
    }

    /// Starts the sampling loop; idempotent.
    internal func start() {
        lock.lock()
        let alreadyStarted = started
        started = true
        lock.unlock()
        guard !alreadyStarted else { return }
        loop = Task.detached(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                let seconds = await MainActor.run { self.status.intervalSeconds }
                do {
                    try await Task.sleep(for: .seconds(max(5, seconds)))
                } catch {
                    return // cancelled: the loop ends with the monitor
                }
            }
        }
    }

    internal func stop() {
        loop?.cancel()
        loop = nil
        lock.lock()
        started = false
        lock.unlock()
    }

    /// Persists and applies a new sampling interval (one of `allowedIntervals`).
    @MainActor
    internal func setInterval(seconds: Int) {
        guard Self.allowedIntervals.contains(seconds) else { return }
        status.intervalSeconds = seconds
        UserDefaults.standard.set(seconds, forKey: Self.intervalDefaultsKey)
    }

    /// One cycle: sample, log, assess, capture when degraded. Public so tests
    /// drive it without the loop.
    internal func tick() async {
        let sample = await collect()
        let (series, assess, now, launchCapture) = locked {
            samples.append(sample)
            if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
            let launch = pendingLaunchCapture
            pendingLaunchCapture = false
            return (samples, dependencies.assess, dependencies.now, launch)
        }

        healthLog.info("\(sample.healthLine())")
        await MainActor.run { status.record(sample: sample) }

        let findings = assess(series, now())
        if !findings.isEmpty {
            let allowed = locked { rateLimiter.allow(now: now()) }
            if allowed {
                _ = await writeBundle(trigger: "degraded state detected", findings: findings.map(\.description), reading: nil)
            } else {
                healthLog.warning("degraded state persists (\(findings.map(\.description).joined(separator: "; "))); bundle rate-limited")
            }
        }
        if launchCapture {
            _ = await writeBundle(trigger: "\(Self.captureOnLaunchArgument) launch argument", findings: [], reading: nil)
        }
    }

    /// A bundle now, regardless of the rate limiter: the user asked.
    @discardableResult
    internal func captureNow(trigger: String = "manual capture") async -> URL? {
        await writeBundle(trigger: trigger, findings: [], reading: nil)
    }

    internal func recentSamples() -> [SessionHealthSample] {
        locked { samples }
    }

    // MARK: - Collection

    private func collect() async -> SessionHealthSample {
        let (deps, previousCounters) = locked { (dependencies, lastCounters) }

        let process = deps.readProcess()
        let main = await MainActor.run { deps.readMainActor() }
        let counters = deps.counters.snapshot()
        let deltas = counters.delta(since: previousCounters)
        let registry = deps.registry.snapshot()

        locked { lastCounters = counters }

        let now = deps.now()
        var sample = SessionHealthSample(timestamp: now, uptimeSeconds: now.timeIntervalSince(deps.processStart))
        sample.footprintBytes = process.footprintBytes
        sample.threadCount = process.threadCount
        sample.fileDescriptors = process.fileDescriptors
        sample.cpuPercent = process.cpuPercent
        sample.hangCount = process.hangCount
        sample.stormCount = process.stormCount
        sample.longestHangMs = process.longestHangMs
        sample.gatewayState = main.gatewayState
        sample.pendingRequests = main.pendingRequests
        sample.reconnectAttempt = main.reconnectAttempt
        sample.eventsSinceLast = previousCounters == nil ? nil : deltas[HealthCounter.gatewayEvents] ?? 0
        sample.lastRTTms = main.lastRTTms
        sample.chatViewModelsAlive = registry.count(LiveObjectKind.chatViewModel)
        sample.sessionsOpen = main.sessionsOpen
        sample.webViewsAlive = registry.count(LiveObjectKind.webView)
        sample.inlineHTMLViewsAlive = registry.count(LiveObjectKind.inlineHTMLView)
        // Not instrumented yet (the canvas is a value type); reported as n/a, not 0.
        sample.artifactCanvasesAlive = nil
        sample.artifactsInMemory = main.artifactsInMemory
        sample.artifactRelayouts = previousCounters == nil ? nil : deltas[HealthCounter.artifactRelayouts] ?? 0
        sample.webViewReloads = previousCounters == nil ? nil : deltas[HealthCounter.webViewReloads] ?? 0
        // The relayout guard is a test-time rule with no runtime counter yet: n/a.
        sample.relayoutGuardTrips = nil
        return sample
    }

    // MARK: - Bundles

    private func writeBundle(trigger: String, findings: [String], reading: SessionHealthMainActorReading?) async -> URL? {
        let (deps, series) = locked { (dependencies, samples) }
        let main = await MainActor.run { deps.readMainActor() }
        let contents = DiagnosticBundleWriter.Contents(
            trigger: trigger,
            findings: findings,
            samples: series.suffix(60).map { $0 },
            gateway: main.gatewaySnapshot,
            registries: deps.registry.snapshot(),
            counters: deps.counters.snapshot(),
            logURL: deps.logURL,
            currentThreadSymbols: Thread.callStackSymbols
        )
        do {
            let folder = try deps.bundleWriter.write(contents, now: deps.now())
            if findings.isEmpty {
                healthLog.notice("diagnostics written to \(folder.path) (\(trigger))")
            } else {
                healthLog.error("degraded state detected (\(findings.joined(separator: "; "))); diagnostics written to \(folder.path)")
            }
            await MainActor.run { status.record(bundle: folder, findings: findings) }
            deps.onBundleWritten(folder, findings)
            return folder
        } catch {
            healthLog.error("diagnostic bundle failed (\(trigger)): \(String(describing: error))")
            return nil
        }
    }
}
