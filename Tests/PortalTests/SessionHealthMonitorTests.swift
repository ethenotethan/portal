import Foundation
import Testing
@testable import Portal

// MARK: - Fixtures

/// `time` is the offset from `base`; uptime is that offset plus a warmed-up
/// process's two minutes, so rule tests are not muted by the warm-up guard.
private func sample(at time: TimeInterval, base: Date = Date(timeIntervalSince1970: 1_800_000_000),
                    memoryMB: Double? = 500, hangs: Int? = 0, pending: Int? = 0, webViews: Int? = 2,
                    chatVMs: Int? = 1, sessions: Int? = 1, threads: Int? = 60, events: Int? = 3, fds: Int? = 120) -> SessionHealthSample {
    var s = SessionHealthSample(timestamp: base.addingTimeInterval(time), uptimeSeconds: time + warmedUp)
    s.footprintBytes = memoryMB.map { UInt64($0 * 1_048_576) }
    s.hangCount = hangs
    s.pendingRequests = pending
    s.webViewsAlive = webViews
    s.chatViewModelsAlive = chatVMs
    s.sessionsOpen = sessions
    s.threadCount = threads
    s.eventsSinceLast = events
    s.fileDescriptors = fds
    s.gatewayState = "connected"
    return s
}

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let warmedUp: TimeInterval = 120

// MARK: - Health line

@Suite("Session health — the sample line")
internal struct SessionHealthSampleTests {
    @Test("the health line is fixed-order key=value pairs with n/a for unreadable metrics")
    internal func healthLine() {
        var s = SessionHealthSample(timestamp: epoch, uptimeSeconds: 125)
        s.footprintBytes = 300 * 1_048_576
        s.threadCount = 42
        s.hangCount = 1
        s.gatewayState = "connected"
        s.pendingRequests = 3
        let line = s.healthLine()
        #expect(line.hasPrefix("uptime_s=125 mem_mb=300 threads=42 fds=n/a cpu_pct=n/a hangs=1 storms=n/a longest_hang_ms=n/a gateway=connected pending_rpc=3"))
        #expect(line.contains(" chat_vms=n/a "))
        #expect(line.hasSuffix(" relayout_guard_trips=n/a"))
        // Greppable: every pair is key=value separated by single spaces.
        #expect(line.split(separator: " ").allSatisfy { $0.contains("=") })
        #expect(line.split(separator: " ").count == 22)
    }

    @Test("samples round-trip through JSON with dates")
    internal func codable() throws {
        let s = sample(at: 30)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(SessionHealthSample.self, from: try encoder.encode(s))
        #expect(back == s)
    }
}

// MARK: - Assessor

@Suite("Session health — degraded-state rules")
internal struct SessionHealthAssessorTests {
    private func assess(_ samples: [SessionHealthSample]) -> [String] {
        let now = samples.last?.timestamp ?? epoch
        return SessionHealthAssessor.assess(samples, now: now).map(\.rule)
    }

    @Test("a healthy series produces no findings")
    internal func healthy() {
        let series = (0..<20).map { sample(at: Double($0) * 30) }
        #expect(assess(series).isEmpty)
        #expect(SessionHealthAssessor.assess([], now: epoch).isEmpty)
    }

    @Test("nothing fires during the warm-up, however bad the launch looks; the same numbers fire afterwards")
    internal func warmUp() {
        var cold = sample(at: 71, memoryMB: 1_599, hangs: 9, threads: 300)
        cold.uptimeSeconds = 71
        #expect(assess([sample(at: 41, memoryMB: 1_494, hangs: 1), cold]).isEmpty)
        let later = [sample(at: 120, memoryMB: 1_599, hangs: 1), sample(at: 150, memoryMB: 1_599, hangs: 9, threads: 300)]
        #expect(assess(later) == ["main-thread-hangs", "thread-count"])
    }

    @Test("memory: over the ceiling, or grown more than 60% in 30 minutes — never measured from the launch samples")
    internal func memory() {
        #expect(assess([sample(at: 0, memoryMB: 2_100)]) == ["memory-ceiling"])
        // Samples start after the warm-up (uptime ≥ 120 s) and span ≥ 10 min.
        var growth = (0..<10).map { sample(at: 120 + Double($0) * 180, memoryMB: 500) }
        growth.append(sample(at: 1_920, memoryMB: 900))
        #expect(assess(growth) == ["memory-growth"])
        // A cold process loading its first screen is not a leak: launch samples are ignored…
        var launch = [sample(at: 0, memoryMB: 9), sample(at: 30, memoryMB: 598), sample(at: 660, memoryMB: 600)]
        launch[0].uptimeSeconds = 0
        launch[1].uptimeSeconds = 30
        #expect(assess(launch).isEmpty, "the 9 MB and 598 MB samples are launch samples; only the warmed-up one counts")
        // …and two samples 30 s apart never qualify, however steep.
        let brief = [sample(at: 600, memoryMB: 300), sample(at: 630, memoryMB: 900)]
        #expect(assess(brief).isEmpty)
        // The same growth spread over more than the window is not a finding.
        var slow = (0..<10).map { sample(at: 120 + Double($0) * 600, memoryMB: 500 + Double($0) * 40) }
        slow.append(sample(at: 6_120, memoryMB: 900))
        #expect(!assess(slow).contains("memory-growth"))
        // Unreadable memory never fires.
        #expect(assess([sample(at: 0, memoryMB: nil)]).isEmpty)
    }

    @Test("main-thread hangs: three or more in the last five minutes, counted against the baseline before the window")
    internal func hangs() {
        var series = (0..<12).map { sample(at: Double($0) * 30, hangs: 5) }   // five old hangs, none recent
        #expect(assess(series).isEmpty)
        series.append(sample(at: 360, hangs: 8))                              // three within the window
        #expect(assess(series) == ["main-thread-hangs"])
        let two = [sample(at: 0, hangs: 0), sample(at: 30, hangs: 2)]
        #expect(assess(two).isEmpty)
    }

    @Test("pending RPC pool: deep for two consecutive samples, not one")
    internal func pendingPool() {
        #expect(assess([sample(at: 0, pending: 3), sample(at: 30, pending: 40)]).isEmpty)
        #expect(assess([sample(at: 0, pending: 30), sample(at: 30, pending: 40)]) == ["pending-rpc-pool"])
    }

    @Test("web views: too many alive, or growing every sample for ten samples")
    internal func webViews() {
        #expect(assess([sample(at: 0, webViews: 11)]) == ["webviews-alive"])
        let growing = (0..<10).map { sample(at: Double($0) * 30, webViews: $0 + 1) }
        #expect(assess(growing) == ["webviews-growing"])
        let plateau = (0..<10).map { sample(at: Double($0) * 30, webViews: min($0 + 1, 5)) }
        #expect(assess(plateau).isEmpty)
        #expect(SessionHealthAssessor.isMonotonicallyGrowing([1, 2, 3], minimumCount: 3))
        #expect(!SessionHealthAssessor.isMonotonicallyGrowing([1, 2, 2], minimumCount: 3))
        #expect(!SessionHealthAssessor.isMonotonicallyGrowing([1, 2], minimumCount: 3))
    }

    @Test("leaked chat view models, thread count, event backlog and descriptors each have a rule")
    internal func remainingRules() {
        #expect(assess([sample(at: 0, chatVMs: 6, sessions: 2)]) == ["chat-viewmodel-leak"])
        #expect(assess([sample(at: 0, chatVMs: 4, sessions: 2)]).isEmpty, "two docks of slack")
        #expect(assess([sample(at: 0, threads: 151)]) == ["thread-count"])
        #expect(assess([sample(at: 0, events: 501)]) == ["event-backlog"])
        #expect(assess([sample(at: 0, fds: 901)]) == ["file-descriptors"])
        let finding = SessionHealthAssessor.assess([sample(at: 0, threads: 200)], now: epoch)[0]
        #expect(finding.description == "thread-count: 200 threads")
    }

    @Test("several rules can fire at once and each names its numbers")
    internal func combined() {
        let findings = SessionHealthAssessor.assess([sample(at: 0, memoryMB: 3_000, threads: 300, fds: 1_000)], now: epoch)
        #expect(findings.map(\.rule) == ["memory-ceiling", "thread-count", "file-descriptors"])
        #expect(findings[0].reason.contains("3000 MB"))
    }

    @Test("the bundle rate limiter allows one write per interval")
    internal func rateLimiter() {
        var limiter = DiagnosticBundleRateLimiter(minimumInterval: 600)
        let first = limiter.allow(now: epoch)
        let tooSoon = limiter.allow(now: epoch.addingTimeInterval(599))
        let later = limiter.allow(now: epoch.addingTimeInterval(600))
        #expect(first)
        #expect(!tooSoon)
        #expect(later)
        #expect(limiter.lastWrite == epoch.addingTimeInterval(600))
    }
}

// MARK: - Registries and counters

@Suite("Session health — live objects and counters")
internal struct LiveObjectRegistryTests {
    private final class Probe {}

    @Test("register/unregister count and remember the peak; tracked objects unregister on dealloc")
    internal func counting() {
        let registry = LiveObjectRegistry()
        registry.register("A")
        registry.register("A")
        registry.unregister("A")
        #expect(registry.count("A") == 1)
        #expect(registry.snapshot().peak("A") == 2)
        registry.unregister("A")
        registry.unregister("A")
        #expect(registry.count("A") == 0, "never negative")
        var probe: Probe? = Probe()
        if let probe { registry.track(probe, as: "Probe") }
        #expect(registry.count("Probe") == 1)
        probe = nil
        #expect(registry.count("Probe") == 0)
        #expect(registry.snapshot().counts["Probe"] == nil, "zero counts are dropped from the snapshot")
        #expect(registry.snapshot().peak("Probe") == 1)
    }

    @Test("concurrent registration is exact")
    internal func concurrency() async {
        let registry = LiveObjectRegistry()
        let counters = HealthCounters()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 {
                group.addTask {
                    registry.register("X")
                    counters.increment("hits")
                }
            }
        }
        #expect(registry.count("X") == 200)
        #expect(registry.snapshot().peak("X") == 200)
        #expect(counters.value("hits") == 200)
    }

    @Test("counter snapshots diff into per-interval deltas")
    internal func deltas() {
        let counters = HealthCounters()
        counters.increment("a", by: 5)
        let first = counters.snapshot()
        counters.increment("a", by: 2)
        counters.increment("b")
        let second = counters.snapshot()
        #expect(second.delta(since: first) == ["a": 2, "b": 1])
        #expect(second.delta(since: nil) == ["a": 7, "b": 1])
        #expect(second.value("a") == 7)
    }
}

// MARK: - Bundle

@Suite("Session health — diagnostic bundle")
internal struct DiagnosticBundleTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portal-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("writes every file, names the trigger and findings, and records a failed sampler instead of failing")
    internal func writesBundle() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("portal.log")
        try (1...2_500).map { "line \($0)" }.joined(separator: "\n").write(to: log, atomically: true, encoding: .utf8)
        let writer = DiagnosticBundleWriter(rootDirectory: root.appendingPathComponent("diagnostics")) { _ in
            throw DiagnosticBundleWriter.SampleToolError.exited(status: 1, output: "not permitted")
        }
        let registry = LiveObjectRegistry()
        registry.register(LiveObjectKind.webView)
        let counters = HealthCounters()
        counters.increment(HealthCounter.artifactRelayouts, by: 4)
        let contents = DiagnosticBundleWriter.Contents(
            trigger: "degraded state detected", findings: ["thread-count: 200 threads"], samples: [sample(at: 0), sample(at: 30)],
            gateway: nil, registries: registry.snapshot(), counters: counters.snapshot(), logURL: log, currentThreadSymbols: ["0 Portal frame"]
        )
        let folder = try writer.write(contents, now: epoch, pid: 4242)
        #expect(folder.lastPathComponent == "2027-01-15T08-00-00Z")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == ["README.txt", "gateway.json", "health.json", "log-tail.txt", "registries.json", "threads.txt"])
        let readme = try String(contentsOf: folder.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains("Trigger:  degraded state detected"))
        #expect(readme.contains("- thread-count: 200 threads"))
        #expect(readme.contains("Send this whole folder"))
        let threads = try String(contentsOf: folder.appendingPathComponent("threads.txt"), encoding: .utf8)
        #expect(threads.contains("0 Portal frame"))
        #expect(threads.contains("sample unavailable: sample exited with status 1: not permitted"))
        #expect(threads.contains("sample 4242 3"))
        let tail = try String(contentsOf: folder.appendingPathComponent("log-tail.txt"), encoding: .utf8)
        #expect(tail.hasPrefix("line 501\n"), "only the last 2,000 lines")
        #expect(tail.hasSuffix("line 2500\n"))
        let health = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("health.json"))) as? [String: Any]
        #expect((health?["samples"] as? [Any])?.count == 2)
        #expect((health?["findings"] as? [String]) == ["thread-count: 200 threads"])
        let registries = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("registries.json"))) as? [String: Any]
        #expect((registries?["counters"] as? [String: Int])?[HealthCounter.artifactRelayouts] == 4)
        #expect((registries?["live"] as? [String: Int])?[LiveObjectKind.webView] == 1)
        let gateway = try String(contentsOf: folder.appendingPathComponent("gateway.json"), encoding: .utf8)
        #expect(gateway.contains("gateway snapshot unavailable"))
    }

    @Test("a gateway snapshot is flattened and encoded; a successful sampler's text is kept")
    internal func gatewaySnapshot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var raw = GatewayDebugSnapshot()
        raw.connectionState = "connected"
        raw.pendingRequestIDs = [7, 9]
        raw.pendingRequestMethods = [7: "session.list", 9: "cron.graph"]
        raw.reconnectAttempt = 2
        raw.recentEvents = [GatewayDebugSnapshot.EventRecord(timestamp: epoch, direction: .inbound, name: "artifact.changed", sessionID: "s1", detail: "d")]
        raw.droppedEventReasons = [GatewayDebugSnapshot.DroppedEventReason(reason: "stale", count: 3, lastAt: epoch)]
        let flat = GatewayDiagnosticSnapshot(raw)
        #expect(flat.pendingRequestCount == 2)
        #expect(flat.pendingRequestMethods == ["7": "session.list", "9": "cron.graph"])
        #expect(flat.recentEvents.first?.direction == "inbound")
        #expect(flat.droppedEventReasons.first?.count == 3)
        let writer = DiagnosticBundleWriter(rootDirectory: root) { pid in "Sampling process \(pid)\nThread 1: main\n" }
        let contents = DiagnosticBundleWriter.Contents(
            trigger: "manual capture", findings: [], samples: [], gateway: flat,
            registries: LiveObjectRegistry().snapshot(), counters: HealthCounters().snapshot(), logURL: nil, currentThreadSymbols: []
        )
        let folder = try writer.write(contents, now: epoch, pid: 1)
        let gateway = try String(contentsOf: folder.appendingPathComponent("gateway.json"), encoding: .utf8)
        #expect(gateway.contains("\"connectionState\" : \"connected\""))
        let threads = try String(contentsOf: folder.appendingPathComponent("threads.txt"), encoding: .utf8)
        #expect(threads.contains("Thread 1: main"))
        #expect(threads.contains("<no symbols>"))
        let tail = try String(contentsOf: folder.appendingPathComponent("log-tail.txt"), encoding: .utf8)
        #expect(tail == "app log location unknown\n")
        let readme = try String(contentsOf: folder.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains("(none — manual capture)"))
        #expect(DiagnosticBundleWriter.logTail(from: root.appendingPathComponent("missing.log")).hasPrefix("app log not readable"))
    }
}

// MARK: - Monitor

@Suite("Session health — the monitor")
@MainActor
internal struct SessionHealthMonitorTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [(URL, [String])] = []
        func record(_ url: URL, _ findings: [String]) { lock.lock(); written.append((url, findings)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return written.count }
        var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return written.isEmpty }
        var last: (URL, [String])? { lock.lock(); defer { lock.unlock() }; return written.last }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = epoch
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    private func makeMonitor(root: URL, clock: Clock, recorder: Recorder, threads: Int = 60,
                             findings: @Sendable @escaping ([SessionHealthSample], Date) -> [SessionHealthAssessor.Finding] = { _, _ in [] },
                             captureOnLaunch: Bool = false) -> SessionHealthMonitor {
        var deps = SessionHealthMonitor.Dependencies()
        deps.registry = LiveObjectRegistry()
        deps.counters = HealthCounters()
        deps.readProcess = {
            SessionHealthProcessReading(footprintBytes: 400 * 1_048_576, threadCount: threads, fileDescriptors: 50,
                                        cpuPercent: 3, hangCount: 0, stormCount: 0, longestHangMs: 0)
        }
        deps.readMainActor = {
            SessionHealthMainActorReading(gatewayState: "connected", pendingRequests: 1, reconnectAttempt: 0, lastRTTms: 12,
                                          gatewaySnapshot: nil, sessionsOpen: 2, artifactsInMemory: 5)
        }
        deps.assess = findings
        deps.bundleWriter = DiagnosticBundleWriter(rootDirectory: root) { _ in "sampled\n" }
        deps.rateLimiter = DiagnosticBundleRateLimiter(minimumInterval: 600)
        deps.logURL = nil
        deps.now = { clock.now() }
        deps.processStart = epoch.addingTimeInterval(-90)
        deps.captureOnFirstSample = captureOnLaunch
        deps.onBundleWritten = { url, findings in recorder.record(url, findings) }
        return SessionHealthMonitor(dependencies: deps)
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portal-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a tick records a full sample, deltas start on the second sample, and status follows")
    internal func tickRecords() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let recorder = Recorder()
        let monitor = makeMonitor(root: root, clock: clock, recorder: recorder)
        await monitor.tick()
        let first = try #require(monitor.recentSamples().last)
        #expect(first.uptimeSeconds == 90)
        #expect(first.threadCount == 60)
        #expect(first.gatewayState == "connected")
        #expect(first.sessionsOpen == 2)
        #expect(first.artifactsInMemory == 5)
        #expect(first.eventsSinceLast == nil, "no previous counters yet")
        #expect(first.artifactRelayouts == nil)
        clock.advance(30)
        await monitor.tick()
        let second = try #require(monitor.recentSamples().last)
        #expect(second.eventsSinceLast == 0)
        #expect(second.artifactRelayouts == 0)
        #expect(monitor.recentSamples().count == 2)
        #expect(monitor.status.latest == second)
        #expect(recorder.isEmpty, "healthy: no bundle")
    }

    @Test("findings write one bundle, then respect the rate limit until the interval passes")
    internal func degradedWritesAndRateLimits() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let recorder = Recorder()
        let monitor = makeMonitor(root: root, clock: clock, recorder: recorder) { _, _ in
            [SessionHealthAssessor.Finding(rule: "thread-count", reason: "200 threads")]
        }
        await monitor.tick()
        #expect(recorder.count == 1)
        #expect(recorder.last?.1 == ["thread-count: 200 threads"])
        #expect(monitor.status.lastBundle == recorder.last?.0)
        #expect(monitor.status.lastFindings == ["thread-count: 200 threads"])
        clock.advance(30)
        await monitor.tick()
        #expect(recorder.count == 1, "rate-limited")
        clock.advance(600)
        await monitor.tick()
        #expect(recorder.count == 2)
        let lastFolder = try #require(recorder.last).0
        let readme = try String(contentsOf: lastFolder.appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains("degraded state detected"))
    }

    @Test("the launch argument captures once on the first sample; manual capture ignores the rate limit")
    internal func launchAndManualCapture() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock()
        let recorder = Recorder()
        let monitor = makeMonitor(root: root, clock: clock, recorder: recorder, captureOnLaunch: true)
        await monitor.tick()
        #expect(recorder.count == 1)
        #expect(recorder.last?.1.isEmpty == true)
        clock.advance(30)
        await monitor.tick()
        #expect(recorder.count == 1, "only on the first sample")
        clock.advance(1)
        let folder = await monitor.captureNow(trigger: "test")
        #expect(folder != nil)
        #expect(recorder.count == 2)
        let readme = try String(contentsOf: try #require(folder).appendingPathComponent("README.txt"), encoding: .utf8)
        #expect(readme.contains("Trigger:  test"))
    }

    @Test("the interval is one of the allowed values and persists")
    internal func interval() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = makeMonitor(root: root, clock: Clock(), recorder: Recorder())
        let before = monitor.status.intervalSeconds
        monitor.setInterval(seconds: 7)
        #expect(monitor.status.intervalSeconds == before, "not an allowed interval")
        monitor.setInterval(seconds: 60)
        #expect(monitor.status.intervalSeconds == 60)
        #expect(UserDefaults.standard.integer(forKey: SessionHealthMonitor.intervalDefaultsKey) == 60)
        monitor.setInterval(seconds: SessionHealthMonitor.defaultIntervalSeconds)
        #expect(SessionHealthMonitor.allowedIntervals == [15, 30, 60])
    }

    @Test("start is idempotent and stop cancels the loop")
    internal func startStop() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let monitor = makeMonitor(root: root, clock: Clock(), recorder: Recorder())
        monitor.start()
        monitor.start()
        try await Task.sleep(for: .milliseconds(200))
        #expect(monitor.recentSamples().count == 1, "one loop, one first sample")
        monitor.stop()
    }

    @Test("the settings summary reads the numbers a person looks at first")
    internal func summary() {
        var s = SessionHealthSample(timestamp: epoch, uptimeSeconds: 3_600)
        s.footprintBytes = 512 * 1_048_576
        s.threadCount = 70
        s.hangCount = 2
        s.pendingRequests = 0
        s.chatViewModelsAlive = 3
        s.webViewsAlive = 4
        #expect(DiagnosticsSettingsSection.summary(s) == "memory 512 MB · threads 70 · hangs 2 · pending RPC 0 · chat VMs 3 · web views 4 · uptime 60 min")
        #expect(DiagnosticsSettingsSection.summary(SessionHealthSample(timestamp: epoch, uptimeSeconds: 0)).hasPrefix("memory n/a · threads n/a"))
    }
}

@Suite("Session health — process reading")
internal struct SessionHealthProcessReadingTests {
    @Test("the real reading returns plausible numbers on this host and never throws")
    internal func realReading() {
        let reading = SessionHealthProcessReading.current()
        #expect((reading.footprintBytes ?? 1) > 0)
        #expect((reading.threadCount ?? 1) > 0)
        #expect((reading.fileDescriptors ?? 1) > 0)
        #expect(reading.hangCount != nil)
        #expect(MainThreadWatchdog.shared.stallStatistics().hangs >= 0)
    }
}
