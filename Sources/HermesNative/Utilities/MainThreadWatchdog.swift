import Foundation
import os

// MARK: - Main-thread hang watchdog
//
// The missing tripwire. This app has fixed the same bug class — a beachball /
// spinning cursor from the main thread blocking — at least a dozen times
// (#107, #111, #138, #145, #146, #193, #210, #217, …). Every one was found the
// same way: a human noticed the cursor spinning and went hunting. There was no
// automated detector, so a hang only became visible when someone happened to be
// watching the UI at the instant it stalled.
//
// The three root-cause classes are all the same symptom — the main run loop
// doesn't get back to `beforeWaiting` in time:
//   1. Expensive pure work in a SwiftUI `body` (parse / layout / highlight).
//   2. Layout-oscillation loops (width↔height feedback).
//   3. Synchronous file I/O + JSON decode on the main actor.
//
// This watchdog catches ALL THREE with one mechanism, at the exact stack that
// caused the stall — so a hang becomes a red console fault (or an assertion,
// with `--hang-fatal`) in dev / CI *before* it reaches a user.
//
// HOW IT WORKS
//   - A CFRunLoopObserver on the MAIN run loop marks the thread "busy" when a
//     turn starts (afterWaiting) and "idle" when it's about to sleep
//     (beforeWaiting). A turn that never reaches beforeWaiting is a hang.
//   - A dedicated background monitor thread polls: if the main thread has been
//     busy longer than `thresholdSeconds`, it SUSPENDS the main thread (so its
//     registers are stable), reads its frame pointer + PC via thread_get_state,
//     walks the frame chain, RESUMES it, then symbolicates and reports. The
//     suspend/resume window is just a register read + a stack-memory walk — no
//     allocation, no logging, no main-thread dependency (or it would deadlock).
//
// TWO FAILURE SHAPES, ONE MECHANISM
//   The single-turn hang above is only HALF the beachball surface. A LAYOUT
//   STORM is the opposite signature: not one long turn, but thousands of short
//   ones — each well under `thresholdSeconds`, so the hang detector never trips
//   — that collectively peg the run loop and spin the cursor (the SessionList /
//   ChatViewModel feedback loop behind #254 was exactly this). To catch it, the
//   observer also accumulates each completed busy interval, and the monitor
//   computes the BUSY FRACTION over a rolling window: if the main thread is busy
//   more than `stormBusyFraction` of any `stormWindowSeconds` window across many
//   short turns, that's a storm. It samples the same suspended-thread stack and
//   fires the same fault — so the storm becomes visible to the tooling instead
//   of only to a human watching the wheel. See #254 (the fix) + this detector
//   (the tripwire that would have caught it).
//
// Everything here is `#if DEBUG`; release builds get an inert shim (below) so
// call sites compile to nothing.

#if DEBUG

/// ON BY DEFAULT in DEBUG builds (this whole file is `#if DEBUG`), opt out
/// with `--no-hang-watchdog`. It started life opt-in (`--hang-watchdog`), which
/// meant ordinary `make run` sessions never had it — beachballs kept reaching
/// users undetected and every one required a debugger session to localize.
/// Detection must be the default for the fault log to replace the debugger.
/// (`--hang-watchdog` is still accepted as a no-op for muscle memory/CI.)
private let hangWatchdogEnabled: Bool =
    !ProcessInfo.processInfo.arguments.contains("--no-hang-watchdog")

/// When set (`--hang-fatal`), a detected hang trips `assertionFailure` instead
/// of only logging a fault — use this in CI UI tests so a hang fails the run.
private let hangFatalEnabled: Bool = ProcessInfo.processInfo.arguments.contains("--hang-fatal")

/// Detects main-thread stalls and reports the offending call stack.
///
/// `@unchecked Sendable`: shared mutable state (`isBusy`, `busySince`,
/// `reportedCurrentHang`) is guarded by `lock`, matching the manual-sync
/// pattern LeakTracker uses to satisfy Swift 6 strict concurrency.
internal final class MainThreadWatchdog: @unchecked Sendable {
    // no_new_singletons exempt in .swiftlint.yml alongside the rest of the perf
    // infra (PerfInstrumentation, PerfSampler) — dev-only, DEBUG-gated tooling.
    internal static let shared = MainThreadWatchdog()

    /// A turn longer than this is treated as a hang. 250ms is well past the
    /// ~100ms perceptible-jank threshold but short enough to catch real stalls;
    /// override with `--hang-threshold-ms=N`.
    private let thresholdSeconds: TimeInterval
    /// How often the monitor thread checks. Finer = lower detection latency but
    /// more wakeups; 50ms keeps the watchdog itself cheap.
    private let pollSeconds: TimeInterval = 0.05

    /// Rolling window over which storm busy-fraction is measured. 1s is long
    /// enough to average out a single legitimately-heavy turn but short enough
    /// that a sustained storm trips within ~a second of onset.
    private let stormWindowSeconds: TimeInterval = 1.0
    /// Fraction of the window the main thread must be busy (across ANY number of
    /// turns) to count as a storm. 0.8 means "spinning 4/5 of the time" — well
    /// clear of normal streaming/animation load, which idles between frames.
    /// Override with `--storm-busy-fraction=N` (0–1).
    private let stormBusyFraction: Double
    /// Don't call a brief flurry a storm: require the window to actually span
    /// the intended duration AND contain enough turns that this is a churn loop,
    /// not one heavy turn the hang detector already owns.
    private let stormMinTurns = 20

    private let lock = NSLock()
    private var isBusy = false
    private var busySince: CFAbsoluteTime = 0
    /// One report per hang — don't spam every poll while the thread stays stuck.
    private var reportedCurrentHang = false

    /// Completed busy intervals (start, end), pruned to the rolling storm
    /// window. Appended on each `beforeWaiting`; summed by the monitor thread to
    /// compute the busy fraction. Guarded by `lock`.
    private var busyIntervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
    /// Latch so a sustained storm reports once, not every poll. Cleared when the
    /// busy fraction falls back below the threshold (edge-triggered, like the
    /// hang latch clearing on the next `afterWaiting`).
    private var reportedCurrentStorm = false

    /// Persistent mach port for the main thread. `pthread_mach_thread_np` does
    /// not create a send right that must be deallocated (unlike
    /// `mach_thread_self`), so it's safe to cache.
    private var mainMachThread: thread_t = 0
    private var observer: CFRunLoopObserver?
    private var monitor: Thread?
    private var started = false

    private init() {
        var seconds = 0.25
        var fraction = 0.8
        for arg in ProcessInfo.processInfo.arguments {
            if arg.hasPrefix("--hang-threshold-ms="),
               let ms = Double(arg.dropFirst("--hang-threshold-ms=".count)), ms > 0 {
                seconds = ms / 1000
            } else if arg.hasPrefix("--storm-busy-fraction="),
                      let f = Double(arg.dropFirst("--storm-busy-fraction=".count)), f > 0, f <= 1 {
                fraction = f
            }
        }
        self.thresholdSeconds = seconds
        self.stormBusyFraction = fraction
    }

    /// Install the run-loop observer (must be called on the main thread) and
    /// spin up the background monitor. Idempotent.
    @MainActor
    internal func start() {
        guard hangWatchdogEnabled, !started else { return }
        started = true
        mainMachThread = pthread_mach_thread_np(pthread_self())

        // Observe the whole cycle so we can bracket each turn: afterWaiting
        // (a turn begins) → beforeWaiting (the turn finished, going idle).
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let obs = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, activities, true, 0
        ) { [weak self] _, activity in
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            self.lock.lock()
            if activity == .afterWaiting {
                self.isBusy = true
                self.busySince = now
                self.reportedCurrentHang = false
            } else if activity == .beforeWaiting {
                // Turn finished — record its busy span so the monitor can sum
                // busy time across many short turns (the storm signature). Prune
                // here too so the array can't grow unbounded on the observer path.
                if self.isBusy {
                    self.busyIntervals.append((start: self.busySince, end: now))
                    self.pruneBusyIntervals(before: now - self.stormWindowSeconds)
                }
                self.isBusy = false
            }
            self.lock.unlock()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
        observer = obs

        let t = Thread { [weak self] in self?.monitorLoop() }
        t.name = "com.researchoors.HermesNative.hang-watchdog"
        t.qualityOfService = .background
        t.start()
        monitor = t

        let ms = Int(thresholdSeconds * 1000)
        let stormPct = Int(stormBusyFraction * 100)
        let stormMs = Int(stormWindowSeconds * 1000)
        perfLog.debug("hang watchdog started (hang=\(ms)ms storm=\(stormPct)%/\(stormMs)ms fatal=\(hangFatalEnabled))")
    }

    // MARK: Monitor loop (background thread)

    private func monitorLoop() {
        while !Thread.current.isCancelled {
            Thread.sleep(forTimeInterval: pollSeconds)
            // Two independent tripwires, same suspend-and-sample machinery: a
            // single overrun turn (hang) or a rolling window of many short ones
            // (storm). A hang in progress takes precedence — its stack is the
            // more actionable one — so only look for a storm if not hung.
            if !checkForHang() {
                checkForStorm()
            }
        }
    }

    /// One long turn: main thread busy past `thresholdSeconds` without reaching
    /// `beforeWaiting`. Returns true if a hang is currently in progress (whether
    /// or not it was reported this poll), so the caller can skip the storm check.
    private func checkForHang() -> Bool {
        lock.lock()
        let busy = isBusy
        let since = busySince
        let alreadyReported = reportedCurrentHang
        lock.unlock()

        guard busy else { return false }
        let elapsed = CFAbsoluteTimeGetCurrent() - since
        guard elapsed >= thresholdSeconds else { return false }

        if alreadyReported { return true }  // hung, already logged — still hung

        // Latch first so we report this hang exactly once even if the walk
        // below is momentarily slow.
        lock.lock()
        reportedCurrentHang = true
        lock.unlock()

        let frames = captureMainThreadStack()
        report(kind: .hang, elapsed: elapsed, busyFraction: 1, frames: frames)
        return true
    }

    /// Many short turns: sum the completed busy intervals over the rolling
    /// window and, if the main thread was busy more than `stormBusyFraction` of
    /// it across at least `stormMinTurns` turns, sample and report once. The
    /// latch clears (edge-triggered) once the fraction drops back down, so a
    /// storm that recurs after settling reports again.
    private func checkForStorm() {
        let now = CFAbsoluteTimeGetCurrent()
        let windowStart = now - stormWindowSeconds

        lock.lock()
        pruneBusyIntervals(before: windowStart)
        let intervals = busyIntervals
        let alreadyReported = reportedCurrentStorm
        lock.unlock()

        let busySeconds = Self.busySeconds(in: intervals, from: windowStart, to: now)
        let fraction = busySeconds / stormWindowSeconds

        guard fraction >= stormBusyFraction, intervals.count >= stormMinTurns else {
            if alreadyReported && fraction < stormBusyFraction {
                lock.lock(); reportedCurrentStorm = false; lock.unlock()
            }
            return
        }
        if alreadyReported { return }

        lock.lock(); reportedCurrentStorm = true; lock.unlock()

        // Sample the stack the same way as a hang — odds are high the main
        // thread is mid-turn (it's busy 80%+ of the time), so the frames point
        // at the churn. An empty sample (caught between turns) still reports the
        // storm; the turn count + fraction alone localize it to a churn loop.
        let frames = captureMainThreadStack()
        report(kind: .storm(turns: intervals.count), elapsed: busySeconds,
               busyFraction: fraction, frames: frames)
    }

    /// Drop busy intervals that ended before the window start. Caller holds
    /// `lock`. Intervals are appended in time order, so a prefix trim suffices.
    private func pruneBusyIntervals(before cutoff: CFAbsoluteTime) {
        var drop = 0
        while drop < busyIntervals.count && busyIntervals[drop].end < cutoff {
            drop += 1
        }
        if drop > 0 { busyIntervals.removeFirst(drop) }
    }

    /// Total busy time within `[from, to]`, clipping each interval to the window
    /// so a turn straddling the window edge only counts its in-window portion.
    /// Pure (no clock, no lock) so the storm math is unit-testable. `internal`
    /// for `@testable` access.
    internal static func busySeconds(
        in intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)],
        from windowStart: CFAbsoluteTime, to windowEnd: CFAbsoluteTime
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for interval in intervals {
            let start = max(interval.start, windowStart)
            let end = min(interval.end, windowEnd)
            if end > start { total += end - start }
        }
        return total
    }

    /// Suspend the main thread, read its register state + walk the frame chain,
    /// then resume. Returns raw return-address program counters (symbolicated
    /// later, after the thread is running again, to keep the suspend window
    /// minimal). Empty on an unsupported architecture or a failed read.
    private func captureMainThreadStack() -> [UInt] {
        guard mainMachThread != 0 else { return [] }
        guard thread_suspend(mainMachThread) == KERN_SUCCESS else { return [] }
        defer { thread_resume(mainMachThread) }
        return Self.walkStack(of: mainMachThread)
    }

    // MARK: Reporting

    /// The two beachball shapes this watchdog reports. Both fault + (under
    /// `--hang-fatal`) assert through the same path; only the framing differs.
    private enum StallKind {
        case hang                 // one turn overran the threshold
        case storm(turns: Int)    // many short turns saturated the window
    }

    private func report(kind: StallKind, elapsed: TimeInterval,
                        busyFraction: Double, frames: [UInt]) {
        let ms = Int(elapsed * 1000)
        let symbols = Self.symbolicate(frames)
        let trace = symbols.isEmpty
            ? "  <no symbols — unsupported architecture or unreadable stack>"
            : symbols.enumerated().map { "  \($0.offset): \($0.element)" }.joined(separator: "\n")

        let header: String
        let assertMessage: String
        switch kind {
        case .hang:
            header = """
            🔴 MAIN-THREAD HANG: main thread blocked \(ms)ms (threshold \(Int(thresholdSeconds * 1000))ms).
            This is a beachball. The stack below is the work that stalled the UI — \
            move it off the main actor, memoize it (RenderMemo), or break the layout loop.
            """
            assertMessage = "Main-thread hang (\(ms)ms) — see perf log for the culprit stack"
        case .storm(let turns):
            let pct = Int(busyFraction * 100)
            header = """
            🔴 MAIN-THREAD STORM: main thread busy \(pct)% of the last \
            \(Int(stormWindowSeconds * 1000))ms across \(turns) short turns \
            (threshold \(Int(stormBusyFraction * 100))%).
            This is a beachball with NO single slow turn — a churn/relayout loop \
            (the #254 SessionList↔ChatViewModel class). The stack below is one \
            sample of the loop; break the feedback cycle driving the re-renders.
            """
            assertMessage = "Main-thread storm (\(turns) turns, \(pct)% busy) — see perf log for a loop sample"
        }
        perfLog.fault("\(header)\n\(trace)")

        if hangFatalEnabled {
            // Escalate to a hard stop so CI UI tests fail on a beachball. Deferred
            // to the main actor so the trap's own backtrace points at the run loop.
            Task { @MainActor in assertionFailure(assertMessage) }
        }
    }

    // MARK: Stack walking (architecture-specific)

    /// Read the target thread's frame pointer + PC, then walk saved
    /// {fp, lr} frame records up the stack. The target MUST be suspended by the
    /// caller so its registers and stack memory are stable.
    private static func walkStack(of thread: thread_t) -> [UInt] {
        var pc: UInt = 0
        var fp: UInt = 0

        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, arm_thread_state64_t.flavor, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return [] }
        pc = UInt(state.__pc)
        fp = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, x86_thread_state64_t.flavor, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return [] }
        pc = UInt(state.__rip)
        fp = UInt(state.__rbp)
        #else
        return []
        #endif

        var pcs: [UInt] = pc != 0 ? [pc] : []
        // Frame-pointer walk. Each frame record on the stack is a pair:
        // [saved frame pointer, saved return address]. Guard against a torn or
        // garbage fp: it must be word-aligned, non-zero, and strictly increasing
        // (the stack grows down, so each caller's fp is at a higher address).
        var current = fp
        for _ in 0..<64 {
            guard current != 0, current.isMultiple(of: 8) else { break }
            guard let framePtr = UnsafePointer<UInt>(bitPattern: current) else { break }
            let savedFP = framePtr[0]
            let savedLR = framePtr[1]
            if savedLR != 0 { pcs.append(savedLR) }
            guard savedFP > current else { break }
            current = savedFP
        }
        return pcs
    }

    /// Turn raw return addresses into human-readable frames via dladdr. Runs
    /// after the main thread has resumed — it must not be inside the suspend
    /// window. Drops this file's own frames so the top of the trace is the
    /// culprit, not the watchdog.
    private static func symbolicate(_ pcs: [UInt]) -> [String] {
        pcs.map { pc -> String in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0,
                  let namePtr = info.dli_sname else {
                return String(format: "0x%016lx", pc)
            }
            let symbol = String(cString: namePtr)
            return Self.demangle(symbol) ?? symbol
        }
    }

    /// Demangle a Swift symbol via the public `swift_demangle` runtime entry
    /// point (the `_stdlib_demangleName` SPI isn't importable from app code).
    /// Returns nil for C/ObjC symbols, which are already readable.
    private static func demangle(_ symbol: String) -> String? {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return nil }
        guard let fn = Self.swiftDemangleFn else { return nil }
        return symbol.withCString { cString in
            guard let out = fn(cString, strlen(cString), nil, nil, 0) else { return nil }
            defer { free(out) }
            return String(cString: out)
        }
    }

    /// C signature of the Swift runtime's `swift_demangle`:
    /// `(mangledName, mangledNameLength, outputBuffer, outputBufferSize, flags)`.
    private typealias SwiftDemangleFn = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    /// Resolved once. `swift_demangle` isn't exposed to Swift, but it's a public
    /// runtime symbol reachable via dlsym (RTLD_DEFAULT). nil if unavailable —
    /// callers fall back to the mangled name, which still identifies the frame.
    private static let swiftDemangleFn: SwiftDemangleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: SwiftDemangleFn.self)
    }()
}

// arm_thread_state64_t / x86_thread_state64_t don't expose their `flavor`
// constant as a typed member the way some Apple headers do in ObjC; provide it
// so the call sites above read cleanly and stay arch-local.
#if arch(arm64)
private extension arm_thread_state64_t {
    static var flavor: thread_state_flavor_t { thread_state_flavor_t(ARM_THREAD_STATE64) }
}
#elseif arch(x86_64)
private extension x86_thread_state64_t {
    static var flavor: thread_state_flavor_t { thread_state_flavor_t(x86_THREAD_STATE64) }
}
#endif

#else

/// Release no-op shim — the watchdog is a dev/CI tripwire, not a shipping
/// feature. Keeps `PerfInstrumentation.bootstrap()` compiling with zero cost.
internal struct MainThreadWatchdog {
    // no_new_singletons exempt in .swiftlint.yml (dev-only perf tooling).
    internal static let shared = MainThreadWatchdog()
    @inline(__always) internal func start() {}
}

#endif
