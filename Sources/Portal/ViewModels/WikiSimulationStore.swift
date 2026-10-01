import SwiftUI
import Combine
import simd

/// The per-frame half of the wiki graph: node positions and velocities, the
/// painter's order, hover, camera and the physics clock.
///
/// `WikiGraphViewModel` is observed by the whole wiki surface — graph host,
/// sidebar, reader, controls bar, events page. When it also published the
/// simulation, every landed physics frame (up to 30 Hz) and every hovered
/// node re-rendered all of them: on the 5,055-page wiki the main thread was
/// 64 % busy with SwiftUI update cycles and whole-surface display-list
/// re-renders while the canvas drawing itself was negligible. Everything
/// that changes per frame or per mouse move now lives here, and only the 2D
/// canvas (and the 3D scene) observes it. Node identity — id, label, path,
/// type — stays on the view model as an immutable `[WikiSimNodeMeta]`,
/// published once per graph load.
///
/// The store also owns the settle policy. Above `liveSimulationNodeLimit`
/// the graph is pre-settled off the main thread and then FROZEN: the 30 Hz
/// clock does not run, and a drag re-simulates only the dragged node's
/// neighbourhood with the rest pinned (see `WikiPhysics2D.Scope`). Below the
/// limit the live simulation behaves as before. In either mode the clock is
/// a `Task` that exists only while there is something to integrate — no
/// timer publisher firing thirty times a second into guards.
@MainActor
internal final class WikiSimulationStore: ObservableObject {

    // MARK: - Policy constants

    /// Node count above which the layout is pre-settled once and then frozen.
    internal static let liveSimulationNodeLimit = 1_500
    /// Alpha at which the live simulation is considered at rest (matches the
    /// tick guard the graph host used to apply).
    internal static let restAlpha: CGFloat = 0.003
    /// Hops of a dragged node's neighbourhood that keep simulating on a frozen graph.
    internal static let neighbourhoodHops = 2
    /// Cap on that neighbourhood, so dragging a 1,796-link hub stays cheap.
    internal static let neighbourhoodCap = 400
    /// Cap on the grid-adjacent nodes folded into the neighbourhood per frame.
    internal static let proximityCap = 200

    private static let alphaMin: CGFloat = 0.002
    private static let alphaDecay: CGFloat = 0.0228
    private static let dragReheat: CGFloat = 0.15
    /// After a drag ends on a frozen graph the neighbourhood relaxes for about a
    /// second, then the clock stops again.
    private static let frozenCooldownAlpha: CGFloat = 0.05
    private static let frozenCooldownDecay: CGFloat = 0.12
    private static let iterationsPerFrame = 2
    private static let frameInterval: Duration = .milliseconds(33)
    /// Pre-settle steps between cancellation checks.
    private static let settleChunk = 8

    private static let springLength3D: Float = 160
    private static let chargeConstant3D: Float = 20000
    private static let centerPull3D: Float = 0.0008
    private static let maxVelocity3D: Float = 30

    // MARK: - Published per-frame state

    @Published internal private(set) var positions: [CGPoint] = []
    internal private(set) var velocities: [CGVector] = []
    @Published internal private(set) var positions3D: [SIMD3<Float>] = []
    internal private(set) var velocities3D: [SIMD3<Float>] = []
    /// Node indices sorted by Y — painter's order for the 2D canvas.
    /// Recomputed only when positions change, never per canvas frame.
    @Published internal private(set) var drawOrder: [Int] = []
    @Published internal private(set) var hoveredNodeIndex: Int?
    @Published internal var zoom: CGFloat = 1.0
    @Published internal var panOffset: CGSize = .zero
    /// True while the camera or cursor is moving; the canvas draws a cheaper
    /// frame while it holds. Published on the leading edge only.
    @Published internal private(set) var isInteracting = false

    internal private(set) var alpha: CGFloat = 1.0
    internal private(set) var draggingIndex: Int?
    /// Size of the canvas the physics centres on; `.zero` before first display.
    internal var canvasSize: CGSize = .zero
    internal let params = WikiPhysics2D.Params.standard

    // MARK: - Topology handed over at reset

    internal private(set) var links: [(sourceIndex: Int, targetIndex: Int)] = []
    internal private(set) var adjacency: [Set<Int>] = []
    internal private(set) var is3D = false

    // MARK: - Bookkeeping

    private var physicsInFlight = false
    /// Bumped whenever the node set is rebuilt; a frame computed against a
    /// stale generation is discarded on completion.
    private var physicsGeneration = 0
    /// Bumped per pre-settle so a superseded relaxation can't adopt.
    private var settleGeneration = 0
    private var settleTask: Task<WikiPhysics2D.Frame?, Never>?
    internal private(set) var isPresettling = false
    private var tickTask: Task<Void, Never>?
    private var tickerSerial = 0
    private var interactionSettleTask: Task<Void, Never>?
    /// Frozen graphs: the dragged node's neighbourhood while it (or its
    /// cooldown) is simulating.
    private var localActive: Set<Int>?
    private var cachedGrid: WikiSpatialGrid?

    internal init() {}

    /// Cap on pre-settle steps. The default (300, cut short once alpha falls
    /// below 0.02 — about 174 steps) is the production schedule; tests lower it
    /// so a 1,600-node settle policy check doesn't spend seconds relaxing.
    internal var presettleStepLimit = 300

    // MARK: - Derived

    internal var nodeCount: Int { is3D ? positions3D.count : positions.count }
    /// Large graphs are pre-settled once and frozen (see the type doc).
    internal var isFrozen: Bool { !is3D && positions.count > Self.liveSimulationNodeLimit }
    internal var isHot: Bool { alpha > Self.restAlpha }
    internal var isDragging: Bool { draggingIndex != nil }
    internal var isTicking: Bool { tickTask != nil }

    /// Whether the clock has anything to do this frame.
    internal var shouldTick: Bool {
        guard !isPresettling, nodeCount > 1 else { return false }
        if isDragging { return true }
        guard isHot else { return false }
        return !isFrozen || localActive != nil
    }

    // MARK: - Node set

    /// Install a freshly seeded node set. Cancels any settle or frame still
    /// computing against the old one. 3D starts its clock at once (it has no
    /// pre-settle); 2D waits for `presettle` or a drag.
    internal func reset(
        positions: [CGPoint], positions3D: [SIMD3<Float>],
        links: [(sourceIndex: Int, targetIndex: Int)], adjacency: [Set<Int>], is3D: Bool
    ) {
        cancelSettle()
        physicsGeneration += 1
        physicsInFlight = false
        stopClock()
        self.is3D = is3D
        self.links = links
        self.adjacency = adjacency
        self.positions = positions
        velocities = Array(repeating: .zero, count: positions.count)
        self.positions3D = positions3D
        velocities3D = Array(repeating: .zero, count: positions3D.count)
        alpha = 1.0
        draggingIndex = nil
        localActive = nil
        setHover(nil)
        invalidateGrid()
        recomputeDrawOrder()
        if is3D { wake() }
    }

    internal func clear() {
        reset(positions: [], positions3D: [], links: [], adjacency: [], is3D: false)
    }

    /// Adopt settled positions at rest (velocities zero, alpha at the floor).
    internal func adopt(positions settled: [CGPoint]) {
        guard settled.count == positions.count else { return }
        positions = settled
        velocities = Array(repeating: .zero, count: settled.count)
        alpha = Self.alphaMin
        localActive = nil
        invalidateGrid()
        recomputeDrawOrder()
    }

    /// Move one node (drag, tests, framing helpers).
    internal func setPosition(_ point: CGPoint, at index: Int) {
        guard positions.indices.contains(index) else { return }
        var moved = positions
        moved[index] = point
        positions = moved
        invalidateGrid()
        recomputeDrawOrder()
    }

    /// Publish a whole frame (the physics completion and the render-count
    /// harness). Velocities default to unchanged.
    internal func applyFrame(positions next: [CGPoint], velocities nextVelocities: [CGVector]? = nil) {
        guard next.count == positions.count else { return }
        if let nextVelocities, nextVelocities.count == next.count { velocities = nextVelocities }
        positions = next
        invalidateGrid()
        recomputeDrawOrder()
    }

    private func recomputeDrawOrder() {
        let ys = positions
        drawOrder = ys.indices.sorted { ys[$0].y < ys[$1].y }
    }

    // MARK: - Hover / interaction

    internal func setHover(_ index: Int?) {
        if hoveredNodeIndex != index { hoveredNodeIndex = index }
    }

    /// Mark a camera/cursor interaction as ongoing and (re)arm the settle
    /// timer; full fidelity returns a beat after the last move.
    internal func noteInteraction() {
        if !isInteracting { isInteracting = true }
        interactionSettleTask?.cancel()
        interactionSettleTask = Task { @MainActor [weak self] in
            // Cancellation (a newer interaction re-armed the timer) is the
            // expected exit — swallow only that, and don't clear the flag.
            do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.isInteracting = false
        }
    }

    // MARK: - Spatial queries

    /// Grid over the current positions, rebuilt lazily after they move.
    internal var grid: WikiSpatialGrid {
        if let cachedGrid { return cachedGrid }
        let built = WikiSpatialGrid(points: positions, cellSize: params.repulsionCutoff)
        cachedGrid = built
        return built
    }

    private func invalidateGrid() { cachedGrid = nil }

    /// The topmost node whose hit box (per-node `hitRadius`) contains the
    /// model-space point, scanning only the 3×3 grid cells around it. Ties go
    /// to the highest index — the same winner as the old back-to-front walk.
    /// Ticks `wiki.hitTest.candidates` with the nodes examined.
    internal func hitTest(modelPoint: CGPoint, hitRadius: (Int) -> CGFloat) -> Int? {
        guard !positions.isEmpty else { return nil }
        var best = -1
        var candidates = 0
        let current = grid
        current.forEachIndex(around: modelPoint) { index in
            candidates += 1
            guard index > best else { return }
            let r = hitRadius(index)
            let p = positions[index]
            if abs(p.x - modelPoint.x) < r && abs(p.y - modelPoint.y) < r { best = index }
        }
        PerfCounter.add("wiki.hitTest.candidates", candidates)
        return best >= 0 ? best : nil
    }

    /// Node indices in the grid cells that intersect a world rect — the
    /// label pass's candidate set instead of every node.
    internal func indices(in rect: CGRect) -> [Int] { grid.indices(intersecting: rect) }

    // MARK: - Drag

    internal func startDragging(index: Int) {
        guard positions.indices.contains(index) else { return }
        draggingIndex = index
        velocities[index] = .zero
        if isFrozen { localActive = neighbourhood(of: index) }
        alpha = max(alpha, Self.dragReheat)
        wake()
    }

    internal func dragNode(index: Int, to modelPoint: CGPoint) {
        guard positions.indices.contains(index) else { return }
        setPosition(modelPoint, at: index)
        alpha = max(alpha, Self.dragReheat)
        wake()
    }

    internal func stopDragging(index: Int) {
        guard draggingIndex == index else { return }
        draggingIndex = nil
        if isFrozen { alpha = min(alpha, Self.frozenCooldownAlpha) }
    }

    /// BFS over `adjacency` from `index`, `neighbourhoodHops` deep, capped at
    /// `neighbourhoodCap` (nearest hops first).
    internal func neighbourhood(of index: Int) -> Set<Int> {
        var seen: Set<Int> = [index]
        var frontier = [index]
        for _ in 0..<Self.neighbourhoodHops where !frontier.isEmpty {
            var next: [Int] = []
            for node in frontier {
                guard adjacency.indices.contains(node) else { continue }
                for neighbour in adjacency[node].sorted() where seen.count < Self.neighbourhoodCap {
                    if seen.insert(neighbour).inserted { next.append(neighbour) }
                }
            }
            frontier = next
        }
        return seen
    }

    /// The active set for a local step: the drag neighbourhood plus whatever
    /// currently sits in the grid cells around the dragged node.
    private func localActiveIndices() -> [Int] {
        var active = localActive ?? []
        if let dragged = draggingIndex, positions.indices.contains(dragged) {
            var added = 0
            grid.forEachIndex(around: positions[dragged]) { index in
                guard added < Self.proximityCap else { return }
                if active.insert(index).inserted { added += 1 }
            }
        }
        return Array(active)
    }

    // MARK: - Clock

    /// Start the 30 Hz clock if there is something to integrate. Idempotent;
    /// the clock stops itself the first frame `shouldTick` is false.
    internal func wake() {
        guard tickTask == nil, shouldTick else { return }
        tickerSerial += 1
        let serial = tickerSerial
        let interval = Self.frameInterval
        tickTask = Task { @MainActor [weak self] in
            while true {
                // Cancellation (reset / clear) is the expected exit.
                do { try await Task.sleep(for: interval) } catch { break }
                guard let self, !Task.isCancelled, self.shouldTick else { break }
                self.tick()
            }
            guard let self, self.tickerSerial == serial else { return }
            self.tickTask = nil
        }
    }

    private func stopClock() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Advance one frame — a no-op unless `shouldTick`.
    internal func tick() {
        guard shouldTick else { return }
        if is3D { tick3D() } else { tick2D() }
    }

    /// Kick off one 2D frame OFF the main thread; `applyPhysicsFrame` merges
    /// it back. Frozen graphs step only the dragged neighbourhood.
    private func tick2D() {
        guard !physicsInFlight, canvasSize != .zero, positions.count > 1 else { return }
        let scope: WikiPhysics2D.Scope
        if isFrozen {
            scope = .local(localActiveIndices(), pinned: draggingIndex)
        } else {
            scope = WikiPhysics2D.Scope(active: nil, pinned: draggingIndex, centering: true)
        }
        physicsInFlight = true
        let generation = physicsGeneration
        let frame = WikiPhysics2D.Frame(positions: positions, velocities: velocities)
        let links = self.links, size = canvasSize, currentAlpha = alpha
        let params = self.params, iterations = Self.iterationsPerFrame
        Task.detached(priority: .userInitiated) { [weak self] in
            let stepped = WikiPhysics2D.step(
                frame, links: links, alpha: currentAlpha, canvasSize: size,
                iterations: iterations, params: params, scope: scope
            )
            await self?.applyPhysicsFrame(stepped, generation: generation)
        }
    }

    /// Merge an off-main frame back. The dragged node keeps its LIVE position
    /// (the drag moved it since the snapshot).
    private func applyPhysicsFrame(_ stepped: WikiPhysics2D.Frame, generation: Int) {
        // A stale frame must not release the in-flight guard — a newer frame owns it.
        guard generation == physicsGeneration else { return }
        physicsInFlight = false
        guard !is3D, stepped.positions.count == positions.count else { return }
        var merged = stepped.positions
        var mergedVelocities = stepped.velocities
        if let dragged = draggingIndex, merged.indices.contains(dragged) {
            merged[dragged] = positions[dragged]
            mergedVelocities[dragged] = .zero
        }
        applyFrame(positions: merged, velocities: mergedVelocities)
        if isDragging {
            alpha = max(alpha, Self.dragReheat)
        } else if isFrozen {
            alpha = WikiPhysics2D.decayed(alpha, toward: Self.alphaMin, rate: Self.frozenCooldownDecay)
            if !isHot { localActive = nil }
        } else {
            alpha = WikiPhysics2D.decayed(alpha, toward: Self.alphaMin, rate: Self.alphaDecay)
        }
    }

    /// The 3D step, unchanged from the view model: O(n²) on the main thread
    /// into local buffers, one publish per tick.
    private func tick3D() {
        let n = positions3D.count
        guard n > 1 else { return }
        var pos = positions3D
        var vel = velocities3D
        let charge = Self.chargeConstant3D
        let maxForce = Float(params.maxRepulsionForce)
        let springK = Float(params.springConstant)
        let friction = Float(params.friction)
        let fAlpha = Float(alpha)
        for _ in 0..<Self.iterationsPerFrame {
            var forces = Array(repeating: SIMD3<Float>.zero, count: n)
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let d = pos[i] - pos[j]
                    let distSq = simd_length_squared(d)
                    guard distSq > 0.01 else { continue }
                    let f = min(charge / distSq, maxForce)
                    let dir = d / sqrt(distSq)
                    forces[i] += dir * f; forces[j] -= dir * f
                }
            }
            for (si, ti) in links where si < n && ti < n {
                let d = pos[ti] - pos[si]
                let dist = simd_length(d)
                guard dist > 0 else { continue }
                let f = (dist - Self.springLength3D) * springK
                let dir = d / dist
                forces[si] += dir * f; forces[ti] -= dir * f
            }
            for i in 0..<n {
                forces[i] -= pos[i] * Self.centerPull3D
                var v = (vel[i] + forces[i] * fAlpha) * friction
                let speed = simd_length(v)
                if speed > Self.maxVelocity3D { v *= Self.maxVelocity3D / speed }
                vel[i] = v
                pos[i] += v
            }
        }
        velocities3D = vel
        positions3D = pos
        alpha = WikiPhysics2D.decayed(alpha, toward: Self.alphaMin, rate: Self.alphaDecay)
    }

    // MARK: - Pre-settle

    /// Relax the seeded 2D layout off the main thread in cancellable chunks
    /// and adopt the result at rest. Returns false when superseded (a reload
    /// or reset happened meanwhile) — the caller must not touch framing then.
    internal func presettle() async -> Bool {
        cancelSettle()
        settleGeneration += 1
        let generation = settleGeneration
        isPresettling = true
        let seed = WikiPhysics2D.Frame(positions: positions, velocities: velocities)
        let links = self.links, params = self.params, iterations = Self.iterationsPerFrame
        let size = canvasSize == .zero ? WikiGraphViewModel.nominalCanvasSize : canvasSize
        // More nodes need more relaxation, but cap the work so the pause is
        // imperceptible even on large graphs.
        let steps = min(presettleStepLimit, max(60, seed.positions.count))
        let chunk = Self.settleChunk
        let task = Task.detached(priority: .userInitiated) { () -> WikiPhysics2D.Frame? in
            var frame = seed
            var a: CGFloat = 1.0
            var done = 0
            while done < steps {
                for _ in 0..<min(chunk, steps - done) {
                    frame = WikiPhysics2D.step(frame, links: links, alpha: a, canvasSize: size, iterations: iterations, params: params)
                    a = WikiPhysics2D.decayed(a, toward: 0.002, rate: 0.0228)
                    done += 1
                    if a < 0.02 { return frame }
                }
                if Task.isCancelled { return nil }
                await Task.yield()
            }
            return frame
        }
        settleTask = task
        let result = await task.value
        guard generation == settleGeneration, let result else { return false }
        settleTask = nil
        isPresettling = false
        adopt(positions: result.positions)
        return true
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        isPresettling = false
        settleGeneration += 1
    }
}
