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
// Everything here is `#if DEBUG`; release builds get an inert shim (below) so
// call sites compile to nothing.

#if DEBUG

/// Whether the hang watchdog was requested at launch. Piggybacks on `--perf`
/// (so anyone already running perf instrumentation gets it free) and also has
/// its own `--hang-watchdog` flag for enabling just the watchdog.
private let hangWatchdogEnabled: Bool = {
    let args = ProcessInfo.processInfo.arguments
    return args.contains("--perf") || args.contains("--hang-watchdog")
}()

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

    private let lock = NSLock()
    private var isBusy = false
    private var busySince: CFAbsoluteTime = 0
    /// One report per hang — don't spam every poll while the thread stays stuck.
    private var reportedCurrentHang = false

    /// Persistent mach port for the main thread. `pthread_mach_thread_np` does
    /// not create a send right that must be deallocated (unlike
    /// `mach_thread_self`), so it's safe to cache.
    private var mainMachThread: thread_t = 0
    private var observer: CFRunLoopObserver?
    private var monitor: Thread?
    private var started = false

    private init() {
        var seconds = 0.25
        for arg in ProcessInfo.processInfo.arguments where arg.hasPrefix("--hang-threshold-ms=") {
            if let ms = Double(arg.dropFirst("--hang-threshold-ms=".count)), ms > 0 {
                seconds = ms / 1000
            }
        }
        self.thresholdSeconds = seconds
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
            self.lock.lock()
            if activity == .afterWaiting {
                self.isBusy = true
                self.busySince = CFAbsoluteTimeGetCurrent()
                self.reportedCurrentHang = false
            } else if activity == .beforeWaiting {
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
        perfLog.debug("hang watchdog started (threshold=\(ms)ms fatal=\(hangFatalEnabled))")
    }

    // MARK: Monitor loop (background thread)

    private func monitorLoop() {
        while !Thread.current.isCancelled {
            Thread.sleep(forTimeInterval: pollSeconds)

            lock.lock()
            let busy = isBusy
            let since = busySince
            let alreadyReported = reportedCurrentHang
            lock.unlock()

            guard busy, !alreadyReported else { continue }
            let elapsed = CFAbsoluteTimeGetCurrent() - since
            guard elapsed >= thresholdSeconds else { continue }

            // Latch first so we report this hang exactly once even if the walk
            // below is momentarily slow.
            lock.lock()
            reportedCurrentHang = true
            lock.unlock()

            let frames = captureMainThreadStack()
            report(elapsed: elapsed, frames: frames)
        }
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

    private func report(elapsed: TimeInterval, frames: [UInt]) {
        let ms = Int(elapsed * 1000)
        let symbols = Self.symbolicate(frames)
        let trace = symbols.isEmpty
            ? "  <no symbols — unsupported architecture or unreadable stack>"
            : symbols.enumerated().map { "  \($0.offset): \($0.element)" }.joined(separator: "\n")
        let message = """
        🔴 MAIN-THREAD HANG: main thread blocked \(ms)ms (threshold \(Int(thresholdSeconds * 1000))ms).
        This is a beachball. The stack below is the work that stalled the UI — \
        move it off the main actor, memoize it (RenderMemo), or break the layout loop.
        \(trace)
        """
        perfLog.fault("\(message)")

        if hangFatalEnabled {
            // Escalate to a hard stop so CI UI tests fail on a hang. Deferred to
            // the main actor so the trap's own backtrace points at the run loop.
            let assertMessage = "Main-thread hang (\(ms)ms) — see perf log for the culprit stack"
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
