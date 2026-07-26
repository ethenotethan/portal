import Foundation
import os

// MetricKit's module imports on macOS, but its subscriber/payload API
// (MXMetricManagerSubscriber, MXMetricPayload, …) is iOS-only — so gate on
// os(iOS), not canImport, or the macOS build fails with "unavailable in macOS".
#if os(iOS)
import MetricKit
#endif

// MARK: - Perf Instrumentation
//
// Debug-only memory/CPU/leak instrumentation. Everything here compiles to a
// no-op (or near no-op) in release builds via `#if DEBUG`. Four cooperating
// pieces, each independently usable:
//
//   1. PerfSampler   — polls real memory footprint + process CPU% on a timer.
//   2. LeakTracker   — `LeakTracker.track(self)` in a class init; warns about
//                      instances that outlive their expected lifetime (cycles).
//   3. PerfSignposter — os_signpost intervals so Instruments shows named
//                      regions on suspect paths (WebSocket loop, feed load,
//                      video lifetime).
//   4. PerfMetrics   — MetricKit subscriber for post-hoc memory/CPU/hang
//                      aggregates on device / TestFlight.
//
// Activation: pass `--perf` as a launch argument (Xcode scheme → Run →
// Arguments) to start live sampling + console logging. The in-app overlay is
// toggled separately via PerfOverlayState.shared.

let perfLog = Logger(subsystem: "com.researchoors.HermesNative", category: "perf")

/// Whether live perf instrumentation was requested at launch (`--perf`).
let perfInstrumentationEnabled: Bool = {
    #if DEBUG
    return ProcessInfo.processInfo.arguments.contains("--perf")
    #else
    return false
    #endif
}()

// MARK: - Process metrics (memory + CPU)

/// A point-in-time snapshot of the process's resource usage.
struct PerfSample: Sendable {
    /// Physical memory footprint in bytes — the value Xcode's gauge and jetsam
    /// use. This is `phys_footprint` from task_vm_info, not resident size.
    var footprintBytes: UInt64 = 0
    /// Aggregate CPU usage across all live threads, as a percentage where 100
    /// means one fully saturated core (can exceed 100 on multi-core work).
    var cpuPercent: Double = 0
    /// Number of live threads in the process.
    var threadCount: Int = 0

    var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
}

/// Reads raw process resource counters via the Mach task APIs.
enum ProcessMetrics {
    /// Current physical memory footprint, in bytes. Returns 0 on failure.
    static func memoryFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Aggregate CPU usage (% of a single core) and live thread count.
    static func cpuUsage() -> (percent: Double, threads: Int) {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threads = threadList else {
            return (0, 0)
        }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: threads.withMemoryRebound(to: Int.self, capacity: 1) { $0.pointee })),
                          vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride))
        }

        // THREAD_BASIC_INFO_COUNT isn't bridged to Swift; derive it from the struct size.
        let basicInfoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        var totalUsage: Double = 0
        for i in 0..<Int(threadCount) {
            var threadInfo = thread_basic_info()
            var infoCount = basicInfoCount
            let kr = withUnsafeMutablePointer(to: &threadInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS, (threadInfo.flags & TH_FLAGS_IDLE) == 0 {
                totalUsage += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return (totalUsage, Int(threadCount))
    }

    static func sample() -> PerfSample {
        let cpu = cpuUsage()
        return PerfSample(footprintBytes: memoryFootprintBytes(),
                          cpuPercent: cpu.percent,
                          threadCount: cpu.threads)
    }
}

// MARK: - Live sampler

/// Polls process metrics on a timer and publishes the latest sample. Drives
/// both the console log (when `--perf` is set) and the in-app overlay.
@MainActor
final class PerfSampler: ObservableObject {
    static let shared = PerfSampler()

    @Published private(set) var latest = PerfSample()
    /// Peak footprint seen this run — useful for spotting a ratcheting leak
    /// even after the OS reclaims a transient spike.
    @Published private(set) var peakFootprintBytes: UInt64 = 0

    private var timer: Timer?
    private let interval: TimeInterval

    private init(interval: TimeInterval = 1.0) {
        self.interval = interval
    }

    func start() {
        guard timer == nil else { return }
        sampleOnce()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleOnce() }
        }
        t.tolerance = interval * 0.25 // let the OS coalesce — don't be the thing that spins
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sampleOnce() {
        let s = ProcessMetrics.sample()
        latest = s
        if s.footprintBytes > peakFootprintBytes {
            peakFootprintBytes = s.footprintBytes
        }
        if perfInstrumentationEnabled {
            let mem = String(format: "%.1f", s.footprintMB)
            let peak = String(format: "%.1f", Double(peakFootprintBytes) / 1_048_576)
            let cpu = String(format: "%.0f", s.cpuPercent)
            perfLog.debug("mem=\(mem)MB peak=\(peak)MB cpu=\(cpu)% threads=\(s.threadCount) live=\(LeakTracker.liveCountSummary())")
        }
    }
}

// MARK: - Leak tracker

#if DEBUG
/// Tracks instance lifecycles of long-lived reference types to surface retain
/// cycles. Call `LeakTracker.track(self)` at the end of a class `init`.
///
/// How it catches leaks:
///   - Increments a per-type live counter on track, decrements on dealloc
///     (via an associated sentinel object that fires in the instance's deinit).
///   - `assertDeallocated(_:after:)` schedules a check: if the instance is
///     still alive after the grace period, it logs a fault. Use this when an
///     object *should* be gone (view dismissed, session closed).
final class LeakTracker {
    private static let lock = NSLock()
    // nonisolated(unsafe): guarded by `lock` below; manual synchronization
    // satisfies the Swift 6 global-mutable-state check.
    nonisolated(unsafe) private static var liveCounts: [String: Int] = [:]

    /// Register an instance. Attaches a sentinel whose deinit decrements the
    /// live count, so we don't need to modify the tracked type's own deinit.
    static func track(_ object: AnyObject, file: StaticString = #fileID) {
        guard perfInstrumentationEnabled else { return }
        let name = String(describing: type(of: object))
        increment(name)
        let sentinel = DeallocSentinel { decrement(name) }
        objc_setAssociatedObject(object, &Self.sentinelKey, sentinel, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        perfLog.debug("＋ \(name) (live: \(liveCount(name)))")
    }

    /// Assert that `object` is released within `seconds`. If it's still alive,
    /// logs a fault — the loudest signal short of a crash. Capture weakly.
    static func assertDeallocated(_ object: AnyObject, after seconds: TimeInterval = 3,
                                  file: StaticString = #fileID, line: UInt = #line) {
        guard perfInstrumentationEnabled else { return }
        let name = String(describing: type(of: object))
        // Wrap the weak ref in a Sendable box so it can cross into the delayed
        // main-actor check without tripping Swift 6 strict concurrency (a bare
        // weak AnyObject is non-Sendable).
        let box = WeakBox(object)
        let line = line
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if box.value != nil {
                perfLog.fault("🔴 LEAK: \(name) still alive \(seconds, format: .fixed(precision: 0))s after expected dealloc (\(String(describing: file)):\(line))")
            }
        }
    }

    /// Sendable weak wrapper so a tracked object can be referenced from a
    /// delayed concurrency context without being "sent" itself.
    private final class WeakBox: @unchecked Sendable {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    static func liveCount(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return liveCounts[name] ?? 0
    }

    /// Compact "Type:count" summary of types with >1 live instance.
    static func liveCountSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        let interesting = liveCounts.filter { $0.value > 0 }.sorted { $0.key < $1.key }
        return interesting.map { "\($0.key):\($0.value)" }.joined(separator: " ")
    }

    private static func increment(_ name: String) {
        lock.lock(); liveCounts[name, default: 0] += 1; lock.unlock()
    }

    private static func decrement(_ name: String) {
        lock.lock()
        liveCounts[name, default: 0] -= 1
        let remaining = liveCounts[name] ?? 0
        lock.unlock()
        perfLog.debug("－ \(name) (live: \(remaining))")
    }

    // Only the address is used as the objc associated-object key; the value is
    // never read. nonisolated(unsafe) because &Self.sentinelKey needs a stable
    // static address and the byte itself is never actually mutated.
    nonisolated(unsafe) private static var sentinelKey: UInt8 = 0
}

/// Fires a closure when deallocated. Attached to a tracked object so its own
/// deinit need not be modified.
private final class DeallocSentinel {
    private let onDealloc: () -> Void
    init(_ onDealloc: @escaping () -> Void) { self.onDealloc = onDealloc }
    deinit { onDealloc() }
}
#else
/// Release no-op shim — keeps call sites compiling with zero overhead.
enum LeakTracker {
    @inline(__always) static func track(_ object: AnyObject, file: StaticString = #fileID) {}
    @inline(__always) static func assertDeallocated(_ object: AnyObject, after seconds: TimeInterval = 3,
                                                     file: StaticString = #fileID, line: UInt = #line) {}
    @inline(__always) static func liveCountSummary() -> String { "" }
}
#endif

// MARK: - Signposter

/// Thin wrapper over OSSignposter for marking intervals on suspect code paths.
/// These show as named regions in Instruments (Time Profiler / Allocations).
enum PerfSignposter {
    static let shared = OSSignposter(subsystem: "com.researchoors.HermesNative", category: "perf-intervals")

    /// Run `body`, bracketing it with a named signpost interval.
    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = shared.beginInterval(name)
        defer { shared.endInterval(name, state) }
        return try body()
    }

    /// Async variant.
    static func interval<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = shared.beginInterval(name)
        defer { shared.endInterval(name, state) }
        return try await body()
    }

    /// Begin an interval you'll end manually (e.g. spanning object lifetime).
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        shared.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        shared.endInterval(name, state)
    }
}

// MARK: - MetricKit aggregates

#if os(iOS) && !targetEnvironment(simulator)
/// Subscribes to MetricKit and logs daily memory/CPU/hang payloads. MetricKit
/// delivers at most once per day (and on next launch after a crash), so this
/// is for trend/regression monitoring on real devices, not live debugging.
final class PerfMetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    // Single long-lived MetricKit delegate; instantiated once at launch.
    nonisolated(unsafe) static let shared = PerfMetricsSubscriber()

    func start() {
        MXMetricManager.shared.add(self)
        perfLog.debug("MetricKit subscriber registered")
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            if let mem = payload.memoryMetrics {
                perfLog.log("MetricKit memory: peak=\(mem.peakMemoryUsage.description) avgSuspended=\(mem.averageSuspendedMemory.averageMeasurement.description)")
            }
            if let cpu = payload.cpuMetrics {
                perfLog.log("MetricKit cpu: cumulativeTime=\(cpu.cumulativeCPUTime.description)")
            }
            if let appTime = payload.applicationTimeMetrics {
                perfLog.log("MetricKit foreground time=\(appTime.cumulativeForegroundTime.description)")
            }
            if let json = String(data: payload.jsonRepresentation(), encoding: .utf8) {
                perfLog.debug("MetricKit payload: \(json)")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
                perfLog.fault("MetricKit hang diagnostics: \(hangs.count) hang(s) reported")
            }
            if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
                perfLog.fault("MetricKit crash diagnostics: \(crashes.count) crash(es) reported")
            }
            if let json = String(data: payload.jsonRepresentation(), encoding: .utf8) {
                perfLog.debug("MetricKit diagnostic: \(json)")
            }
        }
    }
}
#endif

// MARK: - Bootstrap

/// Single entry point called once at app launch. Wires up whichever pieces are
/// active for the current build/configuration.
@MainActor
enum PerfInstrumentation {
    static func bootstrap() {
        #if DEBUG
        if perfInstrumentationEnabled {
            PerfSampler.shared.start()
            perfLog.debug("perf instrumentation started (--perf)")
        }
        // The main-thread hang watchdog (--perf or --hang-watchdog). Its own
        // flag check is inside start(); calling unconditionally keeps the gate
        // in one place. See MainThreadWatchdog.swift.
        MainThreadWatchdog.shared.start()
        #endif
        #if os(iOS) && !targetEnvironment(simulator)
        PerfMetricsSubscriber.shared.start()
        #endif
    }
}
