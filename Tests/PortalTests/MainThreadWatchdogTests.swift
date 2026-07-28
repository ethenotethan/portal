import Foundation
import Testing
@testable import HermesNative

// The storm detector's core is a busy-fraction sum over a rolling window: the
// signature no single-turn hang threshold can see (#254's SessionList relayout
// loop was thousands of sub-250ms turns). These exercise that math directly —
// the run-loop plumbing that feeds it is covered by the macOS hang gate.
//
// The watchdog is `#if DEBUG`; the test target builds DEBUG, so it's visible.
#if DEBUG
@Suite("Main-thread storm detection")
internal struct MainThreadWatchdogTests {

    // A 1s window at t ∈ [10, 11], matching the detector's stormWindowSeconds.
    private let windowStart: CFAbsoluteTime = 10
    private let windowEnd: CFAbsoluteTime = 11

    private func busy(
        _ intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)]
    ) -> TimeInterval {
        MainThreadWatchdog.busySeconds(in: intervals, from: windowStart, to: windowEnd)
    }

    @Test("Many short turns sum toward the busy fraction")
    internal func shortTurnsSum() {
        // 45 turns of 20ms each = 900ms busy in a 1s window → 0.9 fraction.
        // Each turn is far under any 250ms hang threshold, yet together they
        // saturate the run loop — exactly the storm the hang detector misses.
        var intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
        var t = windowStart
        for _ in 0..<45 {
            intervals.append((start: t, end: t + 0.020))
            t += 0.022 // 20ms busy + 2ms idle per turn
        }
        let fraction = busy(intervals) / 1.0
        #expect(abs(fraction - 0.9) < 1e-6)
        #expect(fraction >= 0.8) // trips the default 0.8 threshold
    }

    @Test("A mostly-idle window stays below threshold")
    internal func idleWindowBelowThreshold() {
        // 40 turns of 5ms each = 200ms busy → 0.2 fraction. Normal streaming /
        // animation load idles between frames; it must NOT read as a storm.
        var intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
        var t = windowStart
        for _ in 0..<40 {
            intervals.append((start: t, end: t + 0.005))
            t += 0.025
        }
        #expect(busy(intervals) / 1.0 < 0.8)
    }

    @Test("Intervals straddling the window edge count only their in-window part")
    internal func clipsToWindow() {
        // A turn that started before the window opened (busy 9.5→10.5) only
        // contributes its in-window half; likewise one running past the end.
        let intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = [
            (start: 9.5, end: 10.5),   // clipped to [10, 10.5] = 0.5
            (start: 10.9, end: 11.4),  // clipped to [10.9, 11] = 0.1
        ]
        #expect(abs(busy(intervals) - 0.6) < 1e-9)
    }

    @Test("A fully-out-of-window interval contributes nothing")
    internal func excludesStaleIntervals() {
        let intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = [
            (start: 8.0, end: 9.0), // entirely before the window
        ]
        #expect(busy(intervals) == 0)
    }

    @Test("One long turn fills the window (the hang detector's territory too)")
    internal func singleLongTurn() {
        // A single turn busy the whole window reads as 100% — but this is the
        // hang detector's job (it fires at 250ms); the storm path yields to a
        // hang in progress. The math still reports it faithfully.
        let intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = [
            (start: 10.0, end: 11.0),
        ]
        #expect(abs(busy(intervals) - 1.0) < 1e-9)
    }

    @Test("An empty window is zero busy, not a divide-by-nonsense")
    internal func emptyWindow() {
        #expect(busy([]) == 0)
    }
}
#endif
