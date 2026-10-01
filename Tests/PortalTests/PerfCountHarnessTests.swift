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
/// Hosting-view layout passes are counted while settling but NOT recorded:
/// the runner counted 2 where a local run counts 1 for the same fixture, and
/// a strict ceiling on a 1–3 value would flake. A headless NSHostingView also
/// never realises lazy children, so the lazy-stack prefetch loop (#249, #606)
/// is guarded statically by `collect-layout-smells.py` and
/// `ModelSurfaceRelayoutGuardTests`, not here.
///
/// Fixtures are deterministic constructions (fixed node/link/card counts), so
/// the counts are reproducible to the integer. Change a fixture's size and you
/// must regenerate the baseline (`make perf-baseline`).
@Suite("Perf-count harness", .serialized)
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
    private static let messageCount = 30       // → 30 settled messages with MEDIA: lines
    private static let messageRenders = 20     // → 20 bubble renders of each
    private static let sessionCount = 1_200    // → a sidebar the size of the user's
    private static let sidebarRenders = 20     // → 20 sidebar body evaluations
    private static let boardWorkItems = 32     // → first kanban: 32 cards over 7 lanes (+ per-card move control)
    private static let boardCaseItems = 64     // → second kanban: 64 cards over 12 lanes, and a table with row actions
    private static let wikiNodes = 2_000       // → a large wiki (above the 1,500 freeze limit) …
    private static let wikiLinks = 6_000       // … with the real wiki's link/page ratio
    private static let wikiFrames = 30         // → 30 published physics frames, 30 hover moves
    #if PERF_COUNTERS
    private static let boardStoreArtifacts = 40  // → artifacts in the store the board pane observes
    private static let boardStoreReads = 20    // → sortedArtifacts reads per canvas body evaluation
    #endif

    @MainActor
    @Test("Pure layout, parse and schedule op counts match the committed baseline")
    internal func recordPureOpCounts() throws {
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


        #if PERF_COUNTERS
        // The row inputs read the maintainers of every artifact on every render;
        // the parse must happen once per artifact regardless of render count.
        #expect(parses["artifact.maintainerParse"] == Self.artifactCount, "maintainer parse per render, not per content")
        #endif

        #if PERF_COUNTERS
        // ── Scenario: artifacts.sort (one sort per store change, not per read) ─
        PerfCounter.reset()
        let sortStore = ArtifactStore(fileURL: Self.scratchStoreURL())
        for artifact in Self.makeArtifacts(count: Self.boardStoreArtifacts) {
            sortStore.seedArtifactForTesting(artifact)
        }
        for _ in 0..<Self.boardStoreReads {
            _ = sortStore.sortedArtifacts
            _ = sortStore.sortedArtifactIDs
        }
        sortStore.seedArtifactForTesting(Self.makeBystanderArtifact(rev: 1))
        for _ in 0..<Self.boardStoreReads {
            _ = sortStore.sortedArtifacts
            _ = sortStore.sortedArtifactIDs
        }
        let artifactSorts = PerfCounter.snapshot()
        merged.merge(artifactSorts) { _, new in new }
        // Two publishes (the seed loop's last write, then the bystander), two
        // sorts — however many times the canvas body reads them.
        #expect(artifactSorts["artifacts.sort"] == 2, "artifact sort per read, not per change")

        // ── Scenario: chat.stripMediaTags (one strip per message content, not per render) ─
        PerfCounter.reset()
        let messages = Self.makeMessages(count: Self.messageCount)
        for _ in 0..<Self.messageRenders {
            for message in messages {
                _ = ChatMessageRenderKey(message)
                _ = message.contentWithoutAttachments
            }
        }
        let strips = PerfCounter.snapshot()
        merged.merge(strips) { _, new in new }
        #expect(strips["chat.stripMediaTags"] == Self.messageCount, "MEDIA: strip per render, not per content")

        // ── Scenario: sessions.sidebarSort (four tier sorts per change, not per render) ─
        PerfCounter.reset()
        let sidebar = SessionListViewModel()
        sidebar.sessions = Self.makeSessions(count: Self.sessionCount)
        for _ in 0..<Self.sidebarRenders {
            _ = sidebar.sidebarSections()
        }
        let sorts = PerfCounter.snapshot()
        merged.merge(sorts) { _, new in new }
        // Four tiers (mine, archived, cron, other), each sorted once for the
        // one session list, however many times the sidebar's body reads them.
        #expect(sorts["sessions.sidebarSort"] == 4, "sidebar sort per render, not per change")

        // ── Scenario: gateway.poll.* / artifact.query.coalesced ──────────────
        // The poll schedule and the query coalescer are pure, so a fixed script
        // of ticks (every 4th hidden, every 6th reconnecting, alternating fast
        // and slow, every 5th failed) yields exact skip/back-off tallies. Sizes
        // live here (not as suite constants) because only this instrumented
        // block reads them.
        let pollTicks = 24        // → two full hidden/reconnect cycles
        let coalescedSlots = 5    // → 5 query slots …
        let changesPerFetch = 3   // … each hit by 3 changes mid-fetch
        PerfCounter.reset()
        var policy = GatewayPollPolicy(method: "cron.graph")
        for step in 0..<pollTicks {
            let visible = step % 4 != 3
            let connected = step % 6 != 5
            guard policy.decide(visible: visible, connected: connected) == nil else { continue }
            policy.finished(elapsed: step.isMultiple(of: 2) ? 1 : 12, succeeded: step % 5 != 4)
        }
        _ = policy.decide(visible: true, connected: true)  // leave one call outstanding …
        _ = policy.decide(visible: true, connected: true)  // … so the next tick is skipped
        var coalescer = ArtifactQueryCoalescer<Int>()
        for key in 0..<coalescedSlots {
            _ = coalescer.requestFetch(key)
            for _ in 0..<changesPerFetch {
                _ = coalescer.requestFetch(key)
            }
            while coalescer.finished(key) {}
        }
        let schedule = PerfCounter.snapshot()
        merged.merge(schedule) { _, new in new }
        #expect(schedule["gateway.poll.skip.inFlight"] == 1, "a tick during an outstanding call is skipped")
        #expect(
            schedule["artifact.query.coalesced"] == coalescedSlots * changesPerFetch,
            "every change during a fetch is absorbed, not stacked"
        )
        #endif

        try Self.record(merged)
    }

    #if os(macOS)
    @MainActor
    @Test("Kanban and model host op counts match the committed baseline")
    internal func recordHostOpCounts() throws {
        var merged: [String: Int] = [:]
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

        try Self.record(merged)
    }

    @MainActor
    @Test("Artifact board op counts match the committed baseline")
    internal func recordBoardOpCounts() throws {
        var merged: [String: Int] = [:]
        var passes: Int
        // ── Scenario: board.mount / board.unrelatedChange ────────────────────
        // The production shape that beachballed (a `model` artifact with two
        // kanban boards, three tables, two graphs, a stats strip and six prose
        // views), rendered through the store-observing renderer chain the
        // artifact pane uses. Then ANOTHER artifact in the same store changes.
        // Nothing the board shows has changed, so no card tile — and no popup
        // picker — may be evaluated for it.
        let boardStore = ArtifactStore(fileURL: Self.scratchStoreURL())
        boardStore.seedArtifactForTesting(Self.makeBoardArtifact())
        boardStore.seedArtifactForTesting(Self.makeBystanderArtifact(rev: 1))
        PerfCounter.reset()
        let boardHost = Self.mount(
            StoreDrivenArtifact(store: boardStore, artifactID: Self.boardArtifactID)
                .environmentObject(GatewayCapabilitiesStore())
        )
        passes = Self.settle(boardHost)
        merged.merge(Self.boardCounts("board.mount", passes: passes)) { _, new in new }
        PerfCounter.reset()
        boardHost.host.layoutCount = 0
        boardStore.seedArtifactForTesting(Self.makeBystanderArtifact(rev: 2))
        passes = Self.settle(boardHost)
        let unrelated = PerfCounter.snapshot()
        merged.merge(Self.boardCounts("board.unrelatedChange", passes: passes)) { _, new in new }
        boardHost.window.orderOut(nil)


        #if PERF_COUNTERS
        // An unrelated artifact changing must not reach the board: no card
        // tile, no picker, and at most one card body (the equatable gate).
        #expect(unrelated["view.body.KanbanCardTile"] == nil, "unrelated store change re-rendered kanban cards")
        #expect((unrelated["view.body.ModelCard"] ?? 0) <= 1, "unrelated store change re-rendered the model card")
        // The picker is built only when a card or row asks for it; mounting
        // 96 cards and 64 action rows must construct none.
        #expect(unrelated["view.body.ArtifactChoicePicker"] == nil, "a choice picker was built without a row being triaged")
        #expect(merged["board.mount.view.body.ArtifactChoicePicker"] == 0, "mounting the board built a choice picker")
        #endif

        try Self.record(merged)
    }

    @MainActor
    @Test("Wiki graph op counts match the committed baseline")
    internal func recordWikiOpCounts() throws {
        var merged: [String: Int] = [:]
        // ── Scenario: wiki.physics / wiki.hitTest (pure) ─────────────────────
        // One physics step over a 2k-node wiki laid out on a deterministic
        // spiral (the real wiki's density), then 30 hit tests. With the grid,
        // repulsion visits the 3×3 cells around each node — not every pair.
        let graph = WikiGraphFixtures.graph(nodes: Self.wikiNodes, links: Self.wikiLinks)
        let links = WikiGraphFixtures.indexedLinks(graph)
        let layout = WikiGraphFixtures.spiralPositions(count: Self.wikiNodes, spacing: 60, canvas: Self.surfaceSize)
        PerfCounter.reset()
        _ = WikiPhysics2D.step(WikiPhysics2D.Frame(positions: layout), links: links, alpha: 0.5, canvasSize: Self.surfaceSize, iterations: 1)
        merged.merge(PerfCounter.snapshot()) { _, new in new }

        let viewModel = WikiGraphViewModel()
        viewModel.canvasSize = Self.surfaceSize
        viewModel.presettleEnabled = false
        viewModel.availableWikis = ["perf"]   // the host skips wiki.list discovery
        viewModel.graph = graph
        viewModel.setupSimulation()
        viewModel.simulation.adopt(positions: layout)
        viewModel.fitToView()
        PerfCounter.reset()
        for probe in 0..<Self.wikiFrames {
            let p = layout[probe * 61 % Self.wikiNodes]
            _ = viewModel.hitTest(point: CGPoint(x: p.x * viewModel.zoom + viewModel.panOffset.width, y: p.y * viewModel.zoom + viewModel.panOffset.height))
        }
        merged.merge(PerfCounter.snapshot()) { _, new in new }

        // ── Scenario: wiki.mount / wiki.frames / wiki.hover (host) ───────────
        // The real adaptive host with the sidebar open, then 30 physics frames
        // published by the simulation store, then 30 hover moves. Only the
        // canvas may re-evaluate for either; the graph host, sidebar and
        // controls bar observe the shared view model, which stays silent.
        viewModel.showFileTree = true
        PerfCounter.reset()
        let wikiHost = Self.mount(
            WikiGraphView(viewModel: viewModel)
                .environmentObject(GatewayClientWrapper())
                .environmentObject(GatewayCapabilitiesStore())
        )
        var passes = Self.settle(wikiHost)
        merged.merge(Self.wikiCounts("wiki.mount", passes: passes)) { _, new in new }

        PerfCounter.reset()
        wikiHost.host.layoutCount = 0
        for frame in 1...Self.wikiFrames {
            let shift = CGFloat(frame)
            viewModel.simulation.applyFrame(positions: layout.map { CGPoint(x: $0.x + shift, y: $0.y) })
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        passes = Self.settle(wikiHost)
        let frames = PerfCounter.snapshot()
        merged.merge(Self.wikiCounts("wiki.frames", passes: passes)) { _, new in new }

        PerfCounter.reset()
        wikiHost.host.layoutCount = 0
        for probe in 0..<Self.wikiFrames {
            let p = viewModel.simulation.positions[probe * 61 % Self.wikiNodes]
            viewModel.updateHover(at: CGPoint(x: p.x * viewModel.zoom + viewModel.panOffset.width, y: p.y * viewModel.zoom + viewModel.panOffset.height))
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        passes = Self.settle(wikiHost)
        let hover = PerfCounter.snapshot()
        merged.merge(Self.wikiCounts("wiki.hover", passes: passes)) { _, new in new }
        wikiHost.window.orderOut(nil)

        #if PERF_COUNTERS
        for view in ["WikiGraphView", "WikiFileTreeSidebar", "WikiGraphControlsBar"] {
            #expect(frames["view.body.\(view)"] == nil, "\(view) re-rendered on a physics frame")
            #expect(hover["view.body.\(view)"] == nil, "\(view) re-rendered on hover")
        }
        #expect((frames["view.body.WikiGraph2DCanvas"] ?? 0) > 0, "the canvas must redraw for a frame")
        #expect((hover["view.body.WikiGraph2DCanvas"] ?? 0) > 0, "the canvas must redraw for a hover change")
        #expect((merged["wiki.physics.pairs"] ?? .max) < Self.wikiNodes * (Self.wikiNodes - 1) / 2 / 10, "grid repulsion must visit far fewer than all pairs")
        #expect((merged["wiki.hitTest.candidates"] ?? .max) < Self.wikiFrames * Self.wikiNodes / 10, "hit testing must not scan every node")
        #endif

        try Self.record(merged)
    }
    #endif

    /// The suite is serialized, so the three scenario groups append to one
    /// snapshot in order; the first write of a process starts the file fresh so
    /// a stale counter from an earlier run can never survive into the ratchet.
    @MainActor private static var wroteSnapshot = false

    @MainActor
    private static func record(_ merged: [String: Int]) throws {
        #if PERF_COUNTERS
        #expect(!merged.isEmpty, "instrumented run recorded no op counts")
        guard let out = ProcessInfo.processInfo.environment["PERF_COUNTS_OUT"] else { return }
        let url = URL(fileURLWithPath: out)
        var counts: [String: Int] = [:]
        if wroteSnapshot, let data = try? Data(contentsOf: url),
           let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let existing = doc["counts"] as? [String: Int] {
            counts = existing
        }
        counts.merge(merged) { _, new in new }
        let data = try JSONSerialization.data(
            withJSONObject: ["counts": counts], options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: url)
        wroteSnapshot = true
        #else
        // Uninstrumented: snapshot is a no-op and hostCounts records nothing.
        // We still exercised the layout paths and mounted the surfaces, so
        // this asserts they run clean on the fixtures.
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

    /// The store-observing half of the artifact surfaces: re-evaluates on
    /// every `artifacts` publish, exactly as ArtifactCanvasView /
    /// ArtifactPanelView / ArtifactExpandedOverlay do, and hands the kind
    /// renderer the current record with actions live (pointer-lock callback
    /// included, as the expanded overlay passes it). What the scenario pins
    /// is that none of that re-evaluation reaches the board's cards.
    private struct StoreDrivenArtifact: View {
        @ObservedObject var store: ArtifactStore
        let artifactID: String
        @State private var pageHoldsPointer = false
        var body: some View {
            ScrollView {
                if let artifact = store.artifacts[artifactID] {
                    ArtifactKindRenderer(
                        kind: artifact.kind, content: artifact.content, actionableArtifactID: artifact.id,
                        onPointerLockChange: { pageHoldsPointer = $0 }
                    )
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    /// The current PerfCounter tallies namespaced under `scenario`. `passes`
    /// (hosting-view layout passes to settle) is accepted for the call site's
    /// readability but deliberately not recorded — see the type doc. Empty in
    /// an uninstrumented build so the normal suite keeps its `merged.isEmpty`
    /// assertion.
    private static func hostCounts(_ scenario: String, passes: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        #if PERF_COUNTERS
        _ = passes
        for (key, value) in PerfCounter.snapshot() {
            out["\(scenario).\(key)"] = value
        }
        #endif
        return out
    }

    /// The board scenarios record a FIXED key set, zeros included: the
    /// counters that must stay at zero after an unrelated change have to be
    /// in the baseline to be ratcheted, and the graph views' layout tallies
    /// (which follow hosting-view layout passes) are deliberately left out.
    #if PERF_COUNTERS
    private static let boardBodyCounters = [
        "view.body.ModelCard", "view.body.KanbanBoard", "view.body.KanbanColumn",
        "view.body.KanbanCardTile", "view.body.ArtifactChoicePicker",
        "view.body.ModelEntityTable", "view.body.ModelEntityRow", "view.body.MarkdownContentView",
    ]
    #endif

    private static func boardCounts(_ scenario: String, passes: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        #if PERF_COUNTERS
        _ = passes
        let snapshot = PerfCounter.snapshot()
        for key in boardBodyCounters {
            out["\(scenario).\(key)"] = snapshot[key] ?? 0
        }
        #endif
        return out
    }
    #endif

    private static func scratchStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-harness-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("artifacts.json")
    }

    // MARK: - Fixtures

    /// `count` settled assistant messages, each with prose and a MEDIA: line.
    private static func makeMessages(count: Int) -> [ChatMessage] {
        (0..<count).map { index in
            ChatMessage(
                role: .assistant,
                content: "Reply \(index): " + String(repeating: "lorem ipsum ", count: 40)
                    + "\nMEDIA:http://localhost:8642/v1/files/s\(index)/report-\(index).pdf"
            )
        }
    }

    /// `count` sessions across every tier: owned, archived, cron and foreign.
    private static func makeSessions(count: Int) -> [Session] {
        (0..<count).map { index in
            var session = Session(id: "s\(index)", messageCount: index)
            session.gatewayID = index.isMultiple(of: 4) ? nil : "gw\(index)"
            session.source = index.isMultiple(of: 5) ? "cron" : (index.isMultiple(of: 4) ? "telegram" : nil)
            session.isArchived = index.isMultiple(of: 7)
            session.isPinned = index.isMultiple(of: 11)
            session.lastActive = Date(timeIntervalSince1970: TimeInterval((index * 7919) % 100_000))
            return session
        }
    }

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

    private static let boardArtifactID = "perf-board"
    private static let workLanes = [
        "Inbox", "Working", "CI / Review", "Ready to Merge", "Blocked", "Merged", "Human Hold",
    ]
    private static let caseLanes = [
        "intake", "triage", "design", "ready", "implementing", "review", "validation",
        "merge-ready", "post-merge-validation", "blocked", "regressed", "closed",
    ]

    /// The model artifact under the perf board scenarios: the shape of the
    /// production control-center artifact (21 entity sets, ~60 relations, 15
    /// stacked views: 7 markdown, 1 stats, 2 kanban, 3 tables, 2 graphs).
    private static func makeBoardArtifact() -> LivingArtifact {
        LivingArtifact(
            id: boardArtifactID, kind: "model", title: "Perf board", content: makeBoardJSON(),
            updatedAt: Date(timeIntervalSince1970: 1_000), updatedBy: "cron:observe", rev: 1
        )
    }

    /// An unrelated artifact sharing the store; `rev` is what changes.
    private static func makeBystanderArtifact(rev: Int) -> LivingArtifact {
        LivingArtifact(
            id: "perf-bystander", kind: "map", title: "Bystander",
            content: "{\"markers\":[{\"label\":\"rev \(rev)\",\"lat\":1,\"lng\":\(rev)}]}",
            updatedAt: Date(timeIntervalSince1970: TimeInterval(2_000 + rev)), updatedBy: "cron:other", rev: rev
        )
    }

    private static func jsonItems(_ prefix: String, count: Int, fields: (Int) -> [String: String]) -> String {
        (0..<count).map { index -> String in
            var item = fields(index)
            item["id"] = "\(prefix)\(index)"
            item["title"] = item["title"] ?? "\(prefix.capitalized) \(index)"
            return "{" + item.keys.sorted().map { "\"\($0)\":\"\(item[$0] ?? "")\"" }.joined(separator: ",") + "}"
        }.joined(separator: ",")
    }

    private static func jsonSet(_ name: String, prefix: String, count: Int,
                                fields: @escaping (Int) -> [String: String] = { _ in [:] }) -> String {
        "\"\(name)\":{\"key\":\"id\",\"items\":[\(jsonItems(prefix, count: count, fields: fields))]}"
    }

    private static func makeBoardJSON() -> String {
        let plainSets: [(String, String, Int)] = [
            ("crons", "cron", 8), ("sources", "src", 11), ("artifacts", "art", 10), ("sinks", "sink", 3),
            ("objects", "obj", 1), ("ratchet_crons", "rc", 6), ("ratchet_artifacts", "ra", 7),
            ("ratchet_sources", "rs", 9), ("ratchet_sinks", "rk", 2), ("ratchet_authority", "rauth", 1),
            ("ratchet_objects", "ro", 1), ("product_crons", "pc", 1), ("product_artifacts", "pa", 2),
            ("product_sources", "ps", 7), ("product_sinks", "pk", 1), ("product_authority", "pauth", 1),
            ("product_objects", "po", 1),
        ]
        var sets = [
            jsonSet("work", prefix: "w", count: boardWorkItems) { i in
                ["column": workLanes[i % workLanes.count], "tag": "lane-\(i % 3)",
                 "note": "note \(i) — a deterministic one-line summary", "managed_by": "sync"]
            },
            jsonSet("product_cases", prefix: "case", count: boardCaseItems) { i in
                ["status": caseLanes[i % caseLanes.count], "owner": "o\(i % 4)", "note": "case note \(i)"]
            },
            jsonSet("telemetry", prefix: "t", count: 1) { _ in
                ["generation_runs": "2990", "run_attempts": "3042", "merged": "1268"]
            },
        ]
        sets += plainSets.map { name, prefix, count in
            jsonSet(name, prefix: prefix, count: count) { i in ["kind": name, "state": "s\(i % 2)"] }
        }
        var relations: [String] = []
        func relate(_ from: String, _ fromCount: Int, _ to: String, _ toCount: Int, type: String) {
            for i in 0..<fromCount {
                let fromPrefix = plainSets.first { $0.0 == from }?.1 ?? from
                let toPrefix = plainSets.first { $0.0 == to }?.1 ?? to
                relations.append(
                    "{\"from\":\"\(from)/\(fromPrefix)\(i)\",\"to\":\"\(to)/\(toPrefix)\(i % toCount)\",\"type\":\"\(type)\"}"
                )
            }
        }
        relate("ratchet_sources", 9, "ratchet_crons", 6, type: "feeds")
        relate("ratchet_crons", 6, "ratchet_artifacts", 7, type: "writes")
        relate("ratchet_artifacts", 7, "ratchet_sinks", 2, type: "publishes")
        relate("ratchet_crons", 6, "ratchet_authority", 1, type: "governed_by")
        relate("ratchet_artifacts", 7, "ratchet_objects", 1, type: "models")
        relate("product_sources", 7, "product_crons", 1, type: "feeds")
        relate("product_crons", 1, "product_artifacts", 2, type: "writes")
        relate("product_artifacts", 2, "product_sinks", 1, type: "publishes")
        relate("product_crons", 1, "product_authority", 1, type: "governed_by")
        relate("sources", 11, "crons", 8, type: "feeds")
        relate("crons", 8, "artifacts", 10, type: "writes")
        let lanes = { (names: [String]) in names.map { "\"\($0)\"" }.joined(separator: ",") }
        let prose = { (index: Int) in
            "{\"type\":\"markdown\",\"text\":\"## Section \(index)\\n\\nProse view \(index) with **bold** and a list.\\n\\n- one\\n- two\"}"
        }
        let views = [
            prose(0),
            "{\"type\":\"stats\",\"entities\":[\"telemetry\"]}",
            prose(1),
            "{\"type\":\"kanban\",\"entities\":[\"work\"],\"column\":\"column\",\"columns\":[\(lanes(workLanes))]}",
            prose(2),
            "{\"type\":\"kanban\",\"entities\":[\"product_cases\"],\"column\":\"status\",\"columns\":[\(lanes(caseLanes))]}",
            "{\"type\":\"table\",\"entities\":[\"product_cases\"],\"columns\":[\"id\",\"title\",\"status\",\"owner\"]}",
            prose(3),
            "{\"type\":\"graph\",\"entities\":[\"ratchet_crons\",\"ratchet_artifacts\",\"ratchet_sources\",\"ratchet_sinks\",\"ratchet_authority\",\"ratchet_objects\"]}",
            prose(4),
            "{\"type\":\"graph\",\"entities\":[\"product_crons\",\"product_artifacts\",\"product_sources\",\"product_sinks\",\"product_authority\",\"product_objects\"]}",
            prose(5),
            "{\"type\":\"table\",\"entities\":[\"crons\"]}",
            prose(6),
            "{\"type\":\"table\",\"entities\":[\"sources\",\"artifacts\",\"sinks\",\"objects\"]}",
        ]
        return """
        {"id":"\(boardArtifactID)","title":"Perf board",
         "entities":{\(sets.joined(separator: ","))},
         "relations":[\(relations.joined(separator: ","))],
         "views":[\(views.joined(separator: ","))],
         "actions":{"work":[{"field":"column","type":"choice","options":[\(lanes(workLanes))]}],
                    "product_cases":[{"field":"status","type":"choice","options":[\(lanes(caseLanes))]}]}}
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

// MARK: - Wiki scenario helpers

extension PerfCountHarnessTests {
    /// The wiki scenarios record a FIXED key set, zeros included, for the same
    /// reason as the board: the counters that must stay at zero across frames
    /// and hover have to be in the baseline to be ratcheted. The canvas body
    /// count is deliberately left out of the ratchet — how many of the 30
    /// published frames SwiftUI coalesces into one body evaluation depends on
    /// run-loop timing, which a strict integer ceiling would turn into flake;
    /// the in-test `> 0` assertion covers "the canvas redraws".
    #if PERF_COUNTERS
    fileprivate static let wikiBodyCounters = [
        "view.body.WikiGraphView", "view.body.WikiFileTreeSidebar", "view.body.WikiGraphControlsBar",
    ]
    #endif

    fileprivate static func wikiCounts(_ scenario: String, passes: Int) -> [String: Int] {
        var out: [String: Int] = [:]
        #if PERF_COUNTERS
        _ = passes
        let snapshot = PerfCounter.snapshot()
        for key in wikiBodyCounters {
            out["\(scenario).\(key)"] = snapshot[key] ?? 0
        }
        #endif
        return out
    }
}
