import Testing
import Foundation
@testable import Portal

/// Performance ratchet harness: drives the instrumented hot pure paths with
/// FIXED-SIZE inputs and records how many algorithmic operations each performs.
///
/// The metric is a deterministic work COUNT, not wall-clock time — identical on
/// any machine, so it never flakes on a shared CI runner, and it catches the
/// regression that matters: an O(n) path silently becoming O(n²). It does not
/// catch constant-factor slowdowns (that's the hang gate's job). See
/// PerfCounter and docs/architecture-rules.md ("Performance").
///
/// ## Two modes, one test
/// - **Normal build** (no `PERF_COUNTERS`): `PerfCounter.snapshot()` is a
///   compile-time no-op returning `[:]`, so this test just asserts the layout
///   calls don't crash on the fixtures and returns. It adds nothing to the
///   ordinary `swift test` run.
/// - **Instrumented build** (`swift test -Xswiftc -DPERF_COUNTERS`, used by
///   `make perf-ratchet` and the Performance CI job): the counters are live.
///   The test runs each scenario after `reset()`, collects the tally, and — if
///   `PERF_COUNTS_OUT` names a path — writes the merged snapshot as JSON for
///   `check-perf-ratchet.py` to ratchet against `perf-baseline.json`.
///
/// Fixtures are deterministic constructions (fixed node/link counts), so the
/// op counts are reproducible to the integer. Change a fixture's size and you
/// must regenerate the baseline (`make perf-baseline`).
@Suite("Perf-count harness")
internal struct PerfCountHarnessTests {

    /// Fixed-size inputs. Sizes are chosen large enough that a complexity
    /// regression changes the count by orders of magnitude, but small enough to
    /// run in well under a second. Keep these STABLE — the baseline is keyed to
    /// them; changing a size is a deliberate baseline regen, not a silent edit.
    private static let sankeyLayers = 12       // → a wide, multi-column DAG
    private static let graphNodes = 40         // → 40·39/2 = 780 pairs / iter

    @Test("Instrumented layout op counts match the committed baseline")
    internal func recordOpCounts() throws {
        var merged: [String: Int] = [:]

        // ── Scenario: sankey.layout ──────────────────────────────────────────
        PerfCounter.reset()
        let sankey = Self.makeSankeySpec(layers: Self.sankeyLayers)
        _ = SankeyLayout.layout(sankey)
        merged.merge(PerfCounter.snapshot()) { _, new in new }

        // ── Scenario: graph.layout (force sim) ───────────────────────────────
        PerfCounter.reset()
        let graph = try #require(NetworkGraphSpec.parse(Self.makeGraphJSON(nodes: Self.graphNodes)))
        _ = NetworkGraphLayout.layout(graph, width: 800)
        merged.merge(PerfCounter.snapshot()) { _, new in new }

        #if PERF_COUNTERS
        // The instrumented build must actually have tallied something —
        // otherwise the fixtures aren't hitting the counted paths and the
        // ratchet would silently pass on an empty snapshot.
        #expect(!merged.isEmpty, "instrumented run recorded no op counts")

        if let out = ProcessInfo.processInfo.environment["PERF_COUNTS_OUT"] {
            let doc = ["counts": merged]
            let data = try JSONSerialization.data(
                withJSONObject: doc, options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: URL(fileURLWithPath: out))
        }
        #else
        // Uninstrumented: snapshot is a no-op. We still exercised the layout
        // paths above, so this asserts they run clean on the fixtures.
        #expect(merged.isEmpty)
        #endif
    }

    // MARK: - Fixtures

    /// A layered DAG: `layers` columns of nodes, each node linking to two in
    /// the next layer. Deterministic node names and values → reproducible
    /// column-relaxation and packing counts.
    private static func makeSankeySpec(layers: Int) -> SankeySpec {
        var links: [SankeySpec.Link] = []
        for layer in 0..<(layers - 1) {
            let a = "n\(layer)"
            let b = "n\(layer)b"
            links.append(.init(from: a, to: "n\(layer + 1)", value: 10))
            links.append(.init(from: a, to: "n\(layer + 1)b", value: 6))
            links.append(.init(from: b, to: "n\(layer + 1)", value: 4))
        }
        return SankeySpec(title: "perf", links: links, groups: [:])
    }

    /// A ring of `nodes` with next-neighbour edges — enough edges to exercise
    /// the spring loop without changing the dominant O(n²) repulsion count.
    /// Built through the real `parse` path (NetworkGraphSpec has no memberwise
    /// init) so the fixture is exactly what the app would decode.
    private static func makeGraphJSON(nodes: Int) -> String {
        let nodeJSON = (0..<nodes).map { "{\"id\":\"g\($0)\",\"label\":\"g\($0)\"}" }
        let edgeJSON = (0..<nodes).map {
            "{\"from\":\"g\($0)\",\"to\":\"g\(($0 + 1) % nodes)\"}"
        }
        return "{\"nodes\":[\(nodeJSON.joined(separator: ","))],"
            + "\"edges\":[\(edgeJSON.joined(separator: ","))]}"
    }
}
