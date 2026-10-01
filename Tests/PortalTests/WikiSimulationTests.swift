import Testing
import Foundation
import SwiftUI
@testable import Portal

// MARK: - Spatial grid

@Suite("Wiki spatial grid")
internal struct WikiSpatialGridTests {

    @Test("3×3 neighbourhood query finds every point within a cell size (vs brute force)")
    internal func neighbourQueryMatchesBruteForce() {
        let cell: CGFloat = 60
        let points = WikiGraphFixtures.randomPoints(count: 1_500, in: CGRect(x: -400, y: -300, width: 1_400, height: 900), seed: 11)
        let grid = WikiSpatialGrid(points: points, cellSize: cell)
        #expect(grid.count == points.count)
        var probeRNG = WikiGraphFixtures.SeededGenerator(seed: 12)
        for _ in 0..<200 {
            // Probes inside the cloud's bounds: outside them the probe is clamped
            // to an edge cell, so the block-distance bound below wouldn't hold.
            let probe = CGPoint(
                x: CGFloat.random(in: -400...1_000, using: &probeRNG),
                y: CGFloat.random(in: -300...600, using: &probeRNG)
            )
            let expected = Set(points.indices.filter { hypot(points[$0].x - probe.x, points[$0].y - probe.y) < cell })
            let found = Set(grid.indices(around: probe))
            // Every true neighbour is in the 3×3 block, and nothing in the
            // block is farther than two cells away (the block's diagonal).
            #expect(expected.isSubset(of: found))
            for index in found {
                #expect(abs(points[index].x - probe.x) < cell * 2 + 0.001)
                #expect(abs(points[index].y - probe.y) < cell * 2 + 0.001)
            }
        }
    }

    @Test("Rect query returns a superset of the points inside the rect")
    internal func rectQueryIsSuperset() {
        let points = WikiGraphFixtures.randomPoints(count: 800, in: CGRect(x: 0, y: 0, width: 2_000, height: 1_200), seed: 3)
        let grid = WikiSpatialGrid(points: points, cellSize: 180)
        let rect = CGRect(x: 300, y: 200, width: 500, height: 400)
        let inside = Set(points.indices.filter { rect.contains(points[$0]) })
        let found = Set(grid.indices(intersecting: rect))
        #expect(inside.isSubset(of: found))
        #expect(found.count < points.count, "the query must cull something on a rect a quarter the size of the cloud")
        // Padding by one cell in every direction bounds the over-scan.
        for index in found {
            #expect(rect.insetBy(dx: -grid.cellSize, dy: -grid.cellSize).contains(points[index]))
        }
    }

    @Test("Build is O(n): every point lands in exactly one cell, degenerate inputs survive")
    internal func buildPartitionsPoints() {
        let points = WikiGraphFixtures.randomPoints(count: 500, in: CGRect(x: 0, y: 0, width: 300, height: 300), seed: 7)
        let grid = WikiSpatialGrid(points: points, cellSize: 50)
        var seen = Set<Int>()
        for cell in 0..<grid.cellCount {
            for index in grid.indices(inCell: cell) {
                #expect(seen.insert(index).inserted, "point listed in two cells")
                let coordinate = grid.coordinate(of: points[index])
                #expect(grid.cellIndex(column: coordinate.column, row: coordinate.row) == cell)
            }
        }
        #expect(seen.count == points.count)

        let empty = WikiSpatialGrid(points: [], cellSize: 10)
        #expect(empty.cellCount == 1 && empty.indices(around: .zero).isEmpty)
        let same = WikiSpatialGrid(points: Array(repeating: CGPoint(x: 5, y: 5), count: 40), cellSize: 10)
        #expect(same.indices(around: CGPoint(x: 5, y: 5)).count == 40)
        let wild = WikiSpatialGrid(points: [.zero, CGPoint(x: CGFloat.nan, y: 3), CGPoint(x: 1e9, y: -1e9)], cellSize: 10)
        #expect(wild.cellCount <= WikiSpatialGrid.defaultMaxCellsPerAxis * WikiSpatialGrid.defaultMaxCellsPerAxis)
        #expect(wild.count == 3)
    }
}

// MARK: - Hit testing

@Suite("Wiki hit test")
@MainActor
internal struct WikiHitTestTests {

    /// The old implementation: walk every node back to front, box test.
    private func linearHitTest(_ vm: WikiGraphViewModel, point: CGPoint) -> Int? {
        let mx = (point.x - vm.panOffset.width) / vm.zoom
        let my = (point.y - vm.panOffset.height) / vm.zoom
        for (index, meta) in vm.nodeMeta.enumerated().reversed() {
            let r = vm.nodeRadius(for: meta.type) + 4
            let p = vm.simulation.positions[index]
            if abs(p.x - mx) < r && abs(p.y - my) < r { return index }
        }
        return nil
    }

    private func makeVM(nodes: Int) -> WikiGraphViewModel {
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 1_000, height: 700)
        vm.presettleEnabled = false
        vm.graph = WikiGraphFixtures.graph(nodes: nodes, links: nodes * 2, seed: 21)
        vm.setupSimulation()
        vm.simulation.adopt(positions: WikiGraphFixtures.randomPoints(count: nodes, in: CGRect(x: -200, y: -200, width: 1_400, height: 1_100), seed: 22))
        return vm
    }

    @Test("Grid hit test agrees with the linear scan on a random fixture, including ties")
    internal func hitTestParity() {
        let vm = makeVM(nodes: 1_200)
        vm.zoom = 0.8
        vm.panOffset = CGSize(width: 40, height: -25)
        var rng = WikiGraphFixtures.SeededGenerator(seed: 23)
        var hits = 0
        for _ in 0..<400 {
            let point = CGPoint(x: CGFloat.random(in: 0...1_000, using: &rng), y: CGFloat.random(in: 0...700, using: &rng))
            let expected = linearHitTest(vm, point: point)
            #expect(vm.hitTest(point: point) == expected)
            if expected != nil { hits += 1 }
        }
        #expect(hits > 20, "the probe set must actually land on nodes for parity to mean anything")
        // Aim straight at nodes too, so ties between overlapping nodes are exercised.
        for index in stride(from: 0, to: vm.nodeMeta.count, by: 37) {
            let p = vm.simulation.positions[index]
            let screen = CGPoint(x: p.x * vm.zoom + vm.panOffset.width, y: p.y * vm.zoom + vm.panOffset.height)
            #expect(vm.hitTest(point: screen) == linearHitTest(vm, point: screen))
        }
    }

    @Test("Hover publishes on the simulation store only when the index changes")
    internal func hoverPublishesOnChange() {
        let vm = makeVM(nodes: 50)
        var publishes = 0
        let cancellable = vm.simulation.$hoveredNodeIndex.dropFirst().sink { _ in publishes += 1 }
        let p = vm.simulation.positions[7]
        let screen = CGPoint(x: p.x * vm.zoom + vm.panOffset.width, y: p.y * vm.zoom + vm.panOffset.height)
        vm.updateHover(at: screen)
        vm.updateHover(at: screen)
        vm.updateHover(at: screen)
        #expect(vm.hoveredNodeIndex == vm.hitTest(point: screen))
        #expect(publishes == 1)
        vm.clearHover()
        vm.clearHover()
        #expect(publishes == 2)
        #expect(vm.simulation.isInteracting)
        cancellable.cancel()
    }
}

// MARK: - Physics

@Suite("Wiki physics")
internal struct WikiPhysicsTests {

    @Test("Stepping keeps every position finite, decays alpha and dissipates kinetic energy")
    internal func settlesSmoothly() {
        let graph = WikiGraphFixtures.graph(nodes: 400, links: 900, seed: 31)
        let links = WikiGraphFixtures.indexedLinks(graph)
        let canvas = CGSize(width: 1_280, height: 800)
        var frame = WikiPhysics2D.Frame(positions: WikiGraphFixtures.randomPoints(count: 400, in: CGRect(x: 540, y: 300, width: 200, height: 200), seed: 32))
        var alpha: CGFloat = 1
        var energies: [CGFloat] = []
        for _ in 0..<120 {
            frame = WikiPhysics2D.step(frame, links: links, alpha: alpha, canvasSize: canvas, iterations: 2)
            alpha = WikiPhysics2D.decayed(alpha, toward: 0.002, rate: 0.0228)
            energies.append(frame.kineticEnergy)
        }
        #expect(alpha < 0.1 && alpha > 0.002)
        #expect(frame.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(frame.velocities.allSatisfy { $0.dx.isFinite && $0.dy.isFinite })
        // The layout has spread out of its seed box …
        let spreadX = (frame.positions.map(\.x).max() ?? 0) - (frame.positions.map(\.x).min() ?? 0)
        #expect(spreadX > 600)
        // … and the late frames carry far less motion than the early ones.
        let early = energies[5..<15].reduce(0, +)
        let late = energies[110..<120].reduce(0, +)
        #expect(late < early / 4, "kinetic energy \(early) → \(late)")
        // Still bounded: the centring pull keeps the centroid near the canvas centre.
        let meanX = frame.positions.map(\.x).reduce(0, +) / 400
        #expect(abs(meanX - canvas.width / 2) < 300)
    }

    @Test("Springs pull linked pairs toward the spring length")
    internal func springsHoldPairs() {
        let links: [(sourceIndex: Int, targetIndex: Int)] = [(0, 1)]
        var frame = WikiPhysics2D.Frame(positions: [CGPoint(x: 100, y: 400), CGPoint(x: 700, y: 400)])
        for _ in 0..<300 {
            frame = WikiPhysics2D.step(frame, links: links, alpha: 0.3, canvasSize: CGSize(width: 800, height: 800), iterations: 1)
        }
        let dist = hypot(frame.positions[0].x - frame.positions[1].x, frame.positions[0].y - frame.positions[1].y)
        // Pulled in from 600; repulsion at 120 is 0.55 against a zero spring
        // force, so the pair rests a little past the spring length.
        #expect(dist < 200 && dist > 100, "pair distance \(dist)")
    }

    @Test("A local scope moves only the active nodes and leaves the pinned one in place")
    internal func localScopeMovesNeighbourhoodOnly() {
        let positions = WikiGraphFixtures.randomPoints(count: 300, in: CGRect(x: 0, y: 0, width: 900, height: 900), seed: 41)
        let links: [(sourceIndex: Int, targetIndex: Int)] = (1..<40).map { (0, $0) }
        let active = Array(0..<40)
        let frame = WikiPhysics2D.step(
            WikiPhysics2D.Frame(positions: positions), links: links, alpha: 0.5,
            canvasSize: CGSize(width: 900, height: 900), iterations: 3,
            scope: .local(active, pinned: 0)
        )
        #expect(frame.positions[0] == positions[0], "the dragged node is pinned")
        for index in 40..<300 {
            #expect(frame.positions[index] == positions[index], "node \(index) outside the neighbourhood moved")
        }
        #expect((1..<40).contains { frame.positions[$0] != positions[$0] }, "the neighbourhood must move")
    }

    @Test("Grid repulsion visits well under 1M pairs per iteration on a 5k-node wiki (was 12.8M)")
    internal func pairBudgetAtFiveThousandNodes() {
        let count = 5_000
        let graph = WikiGraphFixtures.graph(nodes: count, links: 15_000, seed: 51)
        let links = WikiGraphFixtures.indexedLinks(graph)
        // Worst case first: the dense random seed, where stride sampling caps the scan.
        let seeded = WikiPhysics2D.Frame(positions: WikiGraphFixtures.randomPoints(count: count, in: CGRect(x: 0, y: 0, width: 400, height: 400), seed: 52))
        #expect(pairsPerIteration(seeded, links: links) < 1_000_000)
        // Then a spread layout with the real wiki's density (~1 node per 60 px).
        let spread = WikiPhysics2D.Frame(positions: WikiGraphFixtures.spiralPositions(count: count, spacing: 60, canvas: CGSize(width: 1_280, height: 800)))
        let pairs = pairsPerIteration(spread, links: links)
        #expect(pairs < 1_000_000)
        #expect(pairs > 0)
        #if PERF_COUNTERS
        // The brute-force count this replaces, for the record.
        #expect(pairs < count * (count - 1) / 2 / 10)
        #endif
    }

    /// Repulsion candidates visited by one iteration. Counted by re-running
    /// the grid scan the step performs, so this holds in uninstrumented builds
    /// too (the PerfCounter is compiled out there).
    private func pairsPerIteration(_ frame: WikiPhysics2D.Frame, links: [(sourceIndex: Int, targetIndex: Int)]) -> Int {
        let params = WikiPhysics2D.Params.standard
        let grid = WikiSpatialGrid(points: frame.positions, cellSize: params.repulsionCutoff)
        var pairs = 0
        for i in frame.positions.indices {
            let center = grid.coordinate(of: frame.positions[i])
            for row in max(0, center.row - 1)...min(grid.rows - 1, center.row + 1) {
                for column in max(0, center.column - 1)...min(grid.columns - 1, center.column + 1) {
                    let cell = grid.cellIndex(column: column, row: row)
                    let count = grid.indices(inCell: cell).count
                    guard count > 0 else { continue }
                    let stride = count > params.maxCellScan ? (count + params.maxCellScan - 1) / params.maxCellScan : 1
                    let visited = (count + stride - 1) / stride
                    pairs += visited - (grid.coordinate(of: frame.positions[i]) == (column, row) && stride == 1 ? 1 : 0)
                }
            }
        }
        PerfCounter.reset()
        _ = WikiPhysics2D.step(frame, links: links, alpha: 0.5, canvasSize: CGSize(width: 1_280, height: 800), iterations: 1, params: params)
        if let counted = PerfCounter.snapshot()["wiki.physics.pairs"] {
            #expect(abs(counted - pairs) <= frame.positions.count, "counter \(counted) vs recount \(pairs)")
            return counted
        }
        return pairs
    }
}

// MARK: - Settle policy

@Suite("Wiki simulation settle policy")
@MainActor
internal struct WikiSimulationSettleTests {

    private func makeVM(nodes: Int, presettle: Bool, settleSteps: Int = 12) -> WikiGraphViewModel {
        let vm = WikiGraphViewModel()
        vm.canvasSize = CGSize(width: 1_000, height: 700)
        vm.presettleEnabled = presettle
        vm.simulation.presettleStepLimit = settleSteps
        vm.graph = WikiGraphFixtures.graph(nodes: nodes, links: nodes * 3, seed: 61)
        vm.setupSimulation()
        return vm
    }

    @Test("Above the limit the graph is pre-settled, then frozen: ticks do nothing without a drag")
    internal func largeGraphFreezesAfterPresettle() async {
        let nodes = WikiSimulationStore.liveSimulationNodeLimit + 100
        let vm = makeVM(nodes: nodes, presettle: true)
        #expect(vm.isSettling)
        #expect(vm.simulation.isFrozen)
        #expect(!vm.simulation.isTicking, "nothing may tick while the pre-settle owns the layout")
        // Wait for the chunked off-main relaxation to land.
        var spins = 0
        while vm.isSettling && spins < 2_000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        #expect(!vm.isSettling)
        #expect(!vm.simulation.isHot)
        #expect(!vm.simulation.shouldTick)
        #expect(!vm.simulation.isTicking)
        let settled = vm.simulation.positions
        #expect(settled.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        for _ in 0..<5 { vm.tick() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(vm.simulation.positions == settled, "a frozen graph must not move on the clock")
        #expect(!vm.simulation.isTicking)
    }

    @Test("A drag on a frozen graph moves only the dragged node's neighbourhood")
    internal func frozenDragMovesNeighbourhoodOnly() async {
        let nodes = WikiSimulationStore.liveSimulationNodeLimit + 100
        let vm = makeVM(nodes: nodes, presettle: false)
        vm.simulation.adopt(positions: WikiGraphFixtures.spiralPositions(count: nodes, spacing: 60, canvas: vm.canvasSize))
        let before = vm.simulation.positions
        let hub = 0
        let neighbourhood = vm.simulation.neighbourhood(of: hub)
        #expect(neighbourhood.count <= WikiSimulationStore.neighbourhoodCap)
        #expect(neighbourhood.count > 1)
        let cells = Set(vm.simulation.grid.indices(around: before[hub]))

        vm.startDragging(index: hub, at: .zero)
        #expect(vm.simulation.isTicking, "a drag starts the clock")
        let target = CGPoint(x: before[hub].x + 30, y: before[hub].y + 30)
        vm.dragNode(index: hub, to: CGPoint(x: target.x * vm.zoom + vm.panOffset.width, y: target.y * vm.zoom + vm.panOffset.height))
        // Let a few off-main frames land (poll: parallel suites contend for the
        // main actor, so a fixed sleep is not enough).
        var frames = 0
        var after = vm.simulation.positions
        while frames < 500 && !after.indices.contains(where: { $0 != hub && after[$0] != before[$0] }) {
            try? await Task.sleep(nanoseconds: 10_000_000)
            after = vm.simulation.positions
            frames += 1
        }
        #expect(after[hub] == target, "the dragged node follows the pointer exactly")
        var moved = 0
        for index in after.indices where index != hub && after[index] != before[index] {
            moved += 1
            let allowed = neighbourhood.contains(index) || cells.contains(index)
            #expect(allowed, "node \(index) moved but is neither a neighbour nor in the grid cells around the drag")
        }
        #expect(moved > 0, "the neighbourhood must react to the drag")
        #expect(moved < nodes / 2)
        vm.stopDragging(index: hub)
        #expect(!vm.simulation.isDragging)
        // The neighbourhood keeps cooling for a beat (still hot, still ticking) …
        #expect(vm.simulation.isHot)
        #expect(vm.simulation.shouldTick)
        // … and once at rest the clock stops itself rather than run on into guards.
        vm.simulation.adopt(positions: vm.simulation.positions)
        #expect(!vm.simulation.shouldTick)
        var spins = 0
        while vm.simulation.isTicking && spins < 400 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            spins += 1
        }
        #expect(!vm.simulation.isTicking)
    }

    @Test("Below the limit the live simulation reheats on drag and comes to rest on its own")
    internal func smallGraphStaysLive() async {
        let vm = makeVM(nodes: 60, presettle: true)
        var spins = 0
        while vm.isSettling && spins < 1_000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        #expect(!vm.simulation.isFrozen)
        #expect(!vm.simulation.isTicking)
        vm.startDragging(index: 3, at: .zero)
        #expect(vm.simulation.isTicking)
        #expect(vm.simulation.isHot)
        vm.stopDragging(index: 3)
        // Alpha decays frame by frame toward rest (~7 s for a real drag). Skip
        // the wait: park the layout at rest and watch the clock stop itself on
        // its next frame rather than run on into guards.
        #expect(vm.simulation.isTicking)
        vm.simulation.adopt(positions: vm.simulation.positions)
        #expect(!vm.simulation.isHot)
        #expect(!vm.simulation.shouldTick)
        spins = 0
        while vm.simulation.isTicking && spins < 500 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            spins += 1
        }
        #expect(!vm.simulation.isTicking)
    }

    @Test("A reload mid-settle cancels the stale relaxation; the fresh graph settles")
    internal func reloadCancelsSettle() async {
        let vm = makeVM(nodes: 2_500, presettle: true)
        #expect(vm.isSettling)
        vm.graph = WikiGraphFixtures.graph(nodes: 40, links: 60, seed: 71)
        vm.setupSimulation()
        var spins = 0
        while vm.isSettling && spins < 1_000 {
            try? await Task.sleep(nanoseconds: 5_000_000)
            spins += 1
        }
        #expect(!vm.isSettling)
        #expect(vm.nodeMeta.count == 40)
        #expect(vm.simulation.positions.count == 40)
        #expect(!vm.simulation.isPresettling)
    }

    @Test("3D keeps its live O(n²) tick on the store: positions move, stay finite and alpha decays")
    internal func threeDTickUnchanged() {
        let vm = makeVM(nodes: 40, presettle: false)
        vm.setRendering3D(true)
        #expect(vm.simulation.is3D)
        #expect(vm.simulation.isTicking, "3D has no pre-settle; its clock starts at reset")
        let before = vm.simulation.positions3D
        let alphaBefore = vm.simulation.alpha
        vm.simulation.tick()
        let after = vm.simulation.positions3D
        #expect(after.count == 40)
        #expect(after != before)
        #expect(after.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        #expect(vm.simulation.alpha < alphaBefore)
        vm.setRendering3D(false)
        #expect(!vm.simulation.is3D)
    }

    @Test("Node identity publishes once per load; frames publish on the store only")
    internal func framesDoNotPublishOnTheViewModel() {
        let vm = makeVM(nodes: 200, presettle: false)
        var viewModelPublishes = 0
        var storePublishes = 0
        let a = vm.objectWillChange.sink { _ in viewModelPublishes += 1 }
        let b = vm.simulation.objectWillChange.sink { _ in storePublishes += 1 }
        let positions = vm.simulation.positions
        for frame in 1...30 {
            vm.simulation.applyFrame(positions: positions.map { CGPoint(x: $0.x + CGFloat(frame), y: $0.y) })
        }
        vm.updateHover(at: CGPoint(x: -5_000, y: -5_000))
        vm.simulation.panOffset.width += 10
        #expect(viewModelPublishes == 0, "the shared view model must stay silent across frames, hover and pan")
        #expect(storePublishes >= 30)
        #expect(vm.drawOrder.count == 200)
        a.cancel(); b.cancel()
    }
}
