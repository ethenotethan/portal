import Testing
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
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
/// ## Three kinds of counter
/// - **Algorithmic op counts** in pure layout code (`sankey.*`, `graph.*`):
///   the dominant loop's iteration tally.
/// - **View-body evaluations** (`<scenario>.view.body.<View>`): how many times
///   a hot SwiftUI body ran while a fixture surface was mounted, and again
///   after one fixed state change (a card moved, an item edited). Catches the
///   "one edit re-renders every row" class without a clock.
/// - **Layout passes to settle** (`<scenario>.layoutPasses`): how many times
///   the hosting view laid out before going quiet after a mount or an update.
///   Catches eager relayout churn. It does NOT reproduce the lazy-stack
///   prefetch loop (#249, #606): a headless NSHostingView never realises lazy
///   children, so that class is guarded statically by
///   `collect-layout-smells.py` and `ModelSurfaceRelayoutGuardTests` instead.
///
/// Fixtures are deterministic constructions (fixed node/link/card counts), so
/// the counts are reproducible to the integer. Change a fixture's size and you
/// must regenerate the baseline (`make perf-baseline`).
@Suite("Perf-count harness")
internal struct PerfCountHarnessTests {

    /// Fixed-size inputs. Sizes are chosen large enough that a complexity
    /// regression changes the count by orders of magnitude, but small enough to
    /// run in well under a second. Keep these STABLE — the baseline is keyed to
    /// them; changing a size is a deliberate baseline regen, not a silent edit.
    private static let sankeyLayers = 12       // → a wide, multi-column DAG
    private static let graphNodes = 40         // → 40·39/2 = 780 pairs / iter
    private static let kanbanColumns = 4       // → 4 lanes …
    private static let kanbanCardsPerColumn = 12  // … 12 cards each, 8 visible (collapsed)
    private static let modelWorkItems = 24     // → kanban + table over the same set
    private static let modelNoteItems = 10     // → a second table
    private static let surfaceSize = CGSize(width: 900, height: 700)
    private static let artifactCount = 40      // → 40 JSON artifacts in the list
    private static let artifactRenders = 20    // → 20 renders of every row

    @MainActor
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

        // ── Scenario: artifact.maintainerParse (one parse per artifact, not per render) ─
        PerfCounter.reset()
        let artifacts = Self.makeArtifacts(count: Self.artifactCount)
        for _ in 0..<Self.artifactRenders {
            for artifact in artifacts {
                _ = ArtifactListRow.Inputs(artifact: artifact, isSelected: false)
                _ = artifact.supportsMaintainers
            }
        }
        let parses = PerfCounter.snapshot()
        merged.merge(parses) { _, new in new }

        #if os(macOS)
        // ── Scenario: kanban.mount / kanban.moveCard ─────────────────────────
        // A board with every lane collapsed to its preview; then one card moves
        // to the next lane. Body counts say how much of the board re-rendered
        // for a one-card change; layout passes say how many times the host
        // laid out before settling.
        let kanbanDriver = JSONDriver(json: Self.makeKanbanJSON(movedCard: nil))
        PerfCounter.reset()
        let kanbanHost = Self.mount(DrivenKanban(driver: kanbanDriver))
        var passes = Self.settle(kanbanHost)
        merged.merge(Self.hostCounts("kanban.mount", passes: passes)) { _, new in new }
        PerfCounter.reset()
        kanbanHost.host.layoutCount = 0
        kanbanDriver.json = Self.makeKanbanJSON(movedCard: 5)
        passes = Self.settle(kanbanHost)
        merged.merge(Self.hostCounts("kanban.moveCard", passes: passes)) { _, new in new }
        kanbanHost.window.orderOut(nil)

        // ── Scenario: model.mount / model.editItem ───────────────────────────
        // A model artifact: prose, a kanban over `work`, a table over `work`,
        // a table over `notes`. Then one work item's title changes.
        let modelDriver = JSONDriver(json: Self.makeModelJSON(editedItem: nil))
        PerfCounter.reset()
        let modelHost = Self.mount(DrivenModel(driver: modelDriver))
        passes = Self.settle(modelHost)
        merged.merge(Self.hostCounts("model.mount", passes: passes)) { _, new in new }
        PerfCounter.reset()
        modelHost.host.layoutCount = 0
        modelDriver.json = Self.makeModelJSON(editedItem: 3)
        passes = Self.settle(modelHost)
        merged.merge(Self.hostCounts("model.editItem", passes: passes)) { _, new in new }
        modelHost.window.orderOut(nil)

        // ── Scenario: markdown.mount ─────────────────────────────────────────
        // A prose document with headings, lists, a table and a code block —
        // the transcript's everyday body.
        PerfCounter.reset()
        let markdownHost = Self.mount(
            ScrollView { MarkdownContentView(text: Self.makeMarkdown(), isStreaming: false).padding() }
        )
        passes = Self.settle(markdownHost)
        merged.merge(Self.hostCounts("markdown.mount", passes: passes)) { _, new in new }
        markdownHost.window.orderOut(nil)
        #endif

        #if PERF_COUNTERS
        // The row inputs read the maintainers of every artifact on every render;
        // the parse must happen once per artifact regardless of render count.
        #expect(parses["artifact.maintainerParse"] == Self.artifactCount, "maintainer parse per render, not per content")
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
        // Uninstrumented: snapshot is a no-op and hostCounts records nothing.
        // We still exercised the layout paths and mounted the surfaces above,
        // so this asserts they run clean on the fixtures.
        #expect(merged.isEmpty)
        #endif
    }

    // MARK: - Hosting (macOS)

    #if os(macOS)
    /// Counts AppKit layout passes on the hosting view.
    @MainActor
    private final class CountingHostingView: NSHostingView<AnyView> {
        var layoutCount = 0
        override func layout() {
            layoutCount += 1
            super.layout()
        }
    }

    @MainActor
    private struct Hosted {
        let window: NSWindow
        let host: CountingHostingView
    }

    /// Externally driven source for a block view, so a scenario can apply one
    /// state change and count what re-evaluates.
    @MainActor
    private final class JSONDriver: ObservableObject {
        @Published var json: String
        init(json: String) { self.json = json }
    }

    private struct DrivenKanban: View {
        @ObservedObject var driver: JSONDriver
        var body: some View {
            KanbanBlockView(json: driver.json, isStreaming: false)
        }
    }

    private struct DrivenModel: View {
        @ObservedObject var driver: JSONDriver
        var body: some View {
            ScrollView {
                ModelBlockView(json: driver.json, isStreaming: false)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @MainActor
    private static func mount(_ view: some View) -> Hosted {
        let host = CountingHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: surfaceSize)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The forced construction pass is required on every host and is not
        // settling churn. Count only follow-up passes scheduled by SwiftUI;
        // AppKit otherwise reports either one or two mount passes depending on
        // the runner SDK's window-install timing.
        host.layoutCount = 0
        return Hosted(window: window, host: host)
    }

    /// Spin the run loop until the host has gone three ticks without another
    /// layout pass (or a generous cap), and return the passes so far.
    @MainActor
    private static func settle(_ hosted: Hosted) -> Int {
        var quiet = 0
        var last = -1
        var spins = 0
        while quiet < 3 && spins < 200 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            spins += 1
            if hosted.host.layoutCount == last {
                quiet += 1
            } else {
                quiet = 0
                last = hosted.host.layoutCount
            }
        }
        return hosted.host.layoutCount
    }

    /// The current PerfCounter tallies namespaced under `scenario`, plus the
    /// layout-pass count. Empty in an uninstrumented build so the normal suite
    /// keeps its `merged.isEmpty` assertion.
    private static func hostCounts(_ scenario: String, passes: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        #if PERF_COUNTERS
        for (key, value) in PerfCounter.snapshot() {
            out["\(scenario).\(key)"] = value
        }
        out["\(scenario).layoutPasses"] = passes
        #endif
        return out
    }
    #endif

    // MARK: - Fixtures

    /// `count` maintained JSON artifacts with distinct, non-trivial bodies.
    private static func makeArtifacts(count: Int) -> [LivingArtifact] {
        (0..<count).map { index in
            let markers = (0..<25).map { "{\"label\":\"m\(index)-\($0)\",\"lat\":\($0),\"lng\":\(index)}" }
            let content = "{\"maintainers\":[\"cron:job-\(index)\"],\"title\":\"Fixture \(index)\",\"markers\":[\(markers.joined(separator: ","))]}"
            return LivingArtifact(id: "fixture-\(index)", kind: "map", title: "Fixture \(index)", content: content,
                                  updatedAt: Date(timeIntervalSince1970: TimeInterval(index)), updatedBy: "cron:job-\(index)", rev: index)
        }
    }

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

    private static let laneNames = ["Inbox", "Working", "Review", "Done"]

    /// A board of `kanbanColumns` lanes × `kanbanCardsPerColumn` cards. Card
    /// `movedCard`, if given, sits one lane over — the single change the
    /// update scenario applies.
    private static func makeKanbanJSON(movedCard: Int?) -> String {
        let total = kanbanColumns * kanbanCardsPerColumn
        let cards = (0..<total).map { i -> String in
            var lane = i % kanbanColumns
            if i == movedCard { lane = (lane + 1) % kanbanColumns }
            return "{\"id\":\"c\(i)\",\"title\":\"Card \(i) — a deterministic title\","
                + "\"column\":\"\(laneNames[lane])\",\"note\":\"note \(i)\"}"
        }
        let columns = laneNames.prefix(kanbanColumns).map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"title\":\"perf board\",\"columns\":[\(columns)],\"cards\":[\(cards.joined(separator: ","))]}"
    }

    /// A model artifact over two entity sets with a kanban and two tables.
    /// Work item `editedItem`, if given, carries a changed title.
    private static func makeModelJSON(editedItem: Int?) -> String {
        let work = (0..<modelWorkItems).map { i -> String in
            let title = i == editedItem ? "Work item \(i) (edited)" : "Work item \(i)"
            return "{\"id\":\"w\(i)\",\"title\":\"\(title)\",\"status\":\"\(laneNames[i % 4])\","
                + "\"owner\":\"o\(i % 3)\",\"points\":\"\(i % 8)\"}"
        }
        let notes = (0..<modelNoteItems).map { i in
            "{\"id\":\"n\(i)\",\"title\":\"Note \(i)\",\"kind\":\"k\(i % 2)\"}"
        }
        return """
        {"id":"perf-model","title":"Perf fixture",
         "entities":{"work":{"key":"id","items":[\(work.joined(separator: ","))]},
                     "notes":{"key":"id","items":[\(notes.joined(separator: ","))]}},
         "views":[
           {"type":"markdown","text":"## Fixture\\n\\nTwo sets, three views."},
           {"type":"kanban","entities":["work"],"column":"status"},
           {"type":"table","entities":["work"]},
           {"type":"table","entities":["notes"]}
         ]}
        """
    }

    /// Everyday transcript prose: headings, lists, a table, a code fence.
    private static func makeMarkdown() -> String {
        var lines: [String] = ["# Perf fixture", "", "Intro paragraph with **bold** and `code`.", ""]
        for section in 0..<4 {
            lines.append("## Section \(section)")
            lines.append("")
            for item in 0..<5 { lines.append("- item \(section).\(item) with some words") }
            lines.append("")
        }
        lines += ["| col a | col b | col c |", "|---|---|---|"]
        for row in 0..<6 { lines.append("| a\(row) | b\(row) | c\(row) |") }
        lines += ["", "```swift", "let x = 1", "print(x)", "```", ""]
        return lines.joined(separator: "\n")
    }
}
