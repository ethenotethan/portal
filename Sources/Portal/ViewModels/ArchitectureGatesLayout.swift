import Foundation

// MARK: - The CI circuit laid out

/// A deterministic layout of a `ci` section as a logic circuit: the input
/// signal (a pull request, or a local check) on the left, every workflow that
/// guards the merge as a lane of gates arranged in columns by dependency depth,
/// one AND gate (the merge) fed by every guarding job, jobs that run after the
/// merge to its right, and a manual band beneath for jobs no event fires.
///
/// Pure geometry: no SwiftUI types, same input → identical output, so it is
/// unit-tested directly and the view only draws it.
internal struct ArchitectureGatesLayout: Equatable {
    internal enum NodeKind: Hashable {
        case trigger
        case job
        case merge
    }

    internal enum LaneKind: Hashable {
        case gates
        case afterMerge
        case manual
    }

    internal struct Node: Hashable, Identifiable {
        internal let id: String
        internal let kind: NodeKind
        internal let label: String
        internal let family: String
        internal let frame: CGRect
        internal let role: ArchitectureGateRole?
        /// The merge gate's input pins, top to bottom.
        internal let inputs: [String]

        internal var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    internal struct Lane: Hashable, Identifiable {
        internal let id: String
        internal let kind: LaneKind
        internal let label: String
        internal let question: String
        internal let family: String
        internal let frame: CGRect
        /// The y of the rail a lane's gate wires drop to before running to the merge.
        internal let rail: CGFloat
    }

    internal struct Wire: Hashable, Identifiable {
        internal let id: String
        internal let source: String
        internal let target: String
        internal let kind: ArchitectureGateWireKind
        internal let label: String?
        /// An orthogonal polyline from the source's right edge to the target's left edge.
        internal let points: [CGPoint]
        /// Where an artifact label sits, above its wire in the gap before the consumer.
        internal let labelAt: CGPoint?
    }

    internal struct Metrics: Equatable {
        internal var nodeWidth: CGFloat = 200
        internal var nodeHeight: CGFloat = 56
        internal var columnGap: CGFloat = 84
        internal var rowGap: CGFloat = 16
        internal var lanePadX: CGFloat = 22
        internal var lanePadY: CGFloat = 18
        internal var laneHead: CGFloat = 34
        internal var laneGap: CGFloat = 22
        internal var triggerWidth: CGFloat = 154
        internal var mergeWidth: CGFloat = 118
        internal var margin: CGFloat = 24
    }

    internal static let familyOrder = ["behavior", "posture", "build", "publication", "release", "maintenance"]
    internal static let inputTriggerID = "trigger:pull_request"
    internal static let manualTriggerID = "trigger:workflow_dispatch"

    internal let nodes: [Node]
    internal let lanes: [Lane]
    internal let wires: [Wire]
    internal let size: CGSize

    internal static let empty = ArchitectureGatesLayout(nodes: [], lanes: [], wires: [], size: .zero)

    // MARK: Queries

    internal func node(_ id: String) -> Node? {
        nodes.first { $0.id == id }
    }

    internal func wires(touching id: String) -> [Wire] {
        wires.filter { $0.source == id || $0.target == id }
    }

    /// Every node upstream of `id` (what must run first), following wires backwards.
    internal func upstream(of id: String) -> Set<String> {
        var seen: Set<String> = []
        var frontier = [id]
        while let current = frontier.popLast() {
            for wire in wires where wire.target == current && !seen.contains(wire.source) {
                seen.insert(wire.source)
                frontier.append(wire.source)
            }
        }
        return seen
    }

    /// Every node downstream of `id` (what waits on it), following wires forwards.
    internal func downstream(of id: String) -> Set<String> {
        var seen: Set<String> = []
        var frontier = [id]
        while let current = frontier.popLast() {
            for wire in wires where wire.source == current && !seen.contains(wire.target) {
                seen.insert(wire.target)
                frontier.append(wire.target)
            }
        }
        return seen
    }

    /// The selection plus everything wired to it, for highlighting.
    internal func connected(to id: String) -> Set<String> {
        upstream(of: id).union(downstream(of: id)).union([id])
    }

    // MARK: Depth and order

    /// Longest `needs` chain beneath a job; a need that is not a job, or a
    /// cycle, contributes nothing rather than recursing forever.
    internal static func depth(of job: ArchitectureGateJob, in jobs: [String: ArchitectureGateJob], seen: Set<String> = []) -> Int {
        guard !job.needs.isEmpty, !seen.contains(job.id) else { return 0 }
        var visited = seen
        visited.insert(job.id)
        let depths = job.needs.map { need -> Int in
            guard let upstream = jobs[need] else { return 0 }
            return depth(of: upstream, in: jobs, seen: visited)
        }
        return 1 + (depths.max() ?? 0)
    }

    internal static func familyRank(_ family: String) -> Int {
        familyOrder.firstIndex(of: family) ?? familyOrder.count
    }

    // MARK: Layout

    internal static func layout(_ document: ArchitectureGatesDocument, metrics: Metrics = Metrics()) -> ArchitectureGatesLayout {
        let jobsByID = document.jobsByID
        var nodes: [Node] = []
        var lanes: [Lane] = []
        var placed: [String: Node] = [:]

        func place(_ node: Node) {
            placed[node.id] = node
            nodes.append(node)
        }

        // Lanes: every workflow with a job that guards the merge, family order then name.
        let gateWorkflows = document.workflows
            .filter { workflow in workflow.jobs.contains { jobsByID[$0]?.role.guardsTheMerge == true } }
            .sorted { lhs, rhs in
                let (l, r) = (familyRank(lhs.family), familyRank(rhs.family))
                return l != r ? l < r : lhs.name < rhs.name
            }
        let jobsX0 = metrics.margin + metrics.triggerWidth + metrics.columnGap
        var maxDepth = 0
        var y = metrics.margin - 8
        let bandTop = y
        for workflow in gateWorkflows {
            let jobs = workflow.jobs.compactMap { jobsByID[$0] }.filter { $0.role.guardsTheMerge }
            var byDepth: [Int: [ArchitectureGateJob]] = [:]
            for job in jobs {
                let jobDepth = depth(of: job, in: jobsByID)
                maxDepth = max(maxDepth, jobDepth)
                byDepth[jobDepth, default: []].append(job)
            }
            let rows = byDepth.values.map(\.count).max() ?? 1
            let laneHeight = metrics.laneHead + metrics.lanePadY + CGFloat(rows) * metrics.nodeHeight
                + CGFloat(rows - 1) * metrics.rowGap + metrics.lanePadY
            lanes.append(Lane(
                id: workflow.id, kind: .gates, label: "\(workflow.label) · \(workflow.name)", question: workflow.question,
                family: workflow.family, frame: CGRect(x: jobsX0 - metrics.lanePadX, y: y, width: 0, height: laneHeight),
                rail: y + laneHeight - 10
            ))
            for (jobDepth, list) in byDepth.sorted(by: { $0.key < $1.key }) {
                for (row, job) in list.enumerated() {
                    let x = jobsX0 + CGFloat(jobDepth) * (metrics.nodeWidth + metrics.columnGap)
                    let nodeY = y + metrics.laneHead + metrics.lanePadY + CGFloat(row) * (metrics.nodeHeight + metrics.rowGap)
                    place(Node(id: job.id, kind: .job, label: job.name, family: workflow.family,
                               frame: CGRect(x: x, y: nodeY, width: metrics.nodeWidth, height: metrics.nodeHeight), role: job.role, inputs: []))
                }
            }
            y += laneHeight + metrics.laneGap
        }
        let bandBottom = y - metrics.laneGap
        let laneRight = jobsX0 + CGFloat(maxDepth + 1) * (metrics.nodeWidth + metrics.columnGap) - metrics.columnGap + metrics.lanePadX
        lanes = lanes.map { lane in
            Lane(id: lane.id, kind: lane.kind, label: lane.label, question: lane.question, family: lane.family,
                 frame: CGRect(x: lane.frame.minX, y: lane.frame.minY, width: laneRight - lane.frame.minX, height: lane.frame.height), rail: lane.rail)
        }
        let bandMid = (bandTop + max(bandBottom, bandTop + 54)) / 2

        // The input signal, centred on the gate band.
        // The input signal: the pull-request trigger when there is one, else the
        // first event the service declares (a local service's own check).
        let inputTrigger = document.triggers.first { $0.id == inputTriggerID } ?? document.triggers.first
        let inputID = inputTrigger?.id ?? inputTriggerID
        let inputLabel = inputTrigger.map { "\($0.event) → main" } ?? "pull_request → main"
        place(Node(id: inputID, kind: .trigger, label: inputLabel, family: "trigger",
                   frame: CGRect(x: metrics.margin, y: bandMid - 27, width: metrics.triggerWidth, height: 54), role: nil, inputs: []))

        // The merge: one AND gate, one input pin per guarding job that was placed.
        let mergeX = laneRight + metrics.columnGap + 26
        var mergeNode: Node?
        if let merge = document.merge {
            let inputs = merge.inputs.filter { placed[$0] != nil }
            let mergeHeight = max(88, CGFloat(inputs.count) * 13 + 26)
            let node = Node(id: merge.id, kind: .merge, label: merge.label, family: "merge",
                            frame: CGRect(x: mergeX, y: bandMid - mergeHeight / 2, width: metrics.mergeWidth, height: mergeHeight), role: nil, inputs: inputs)
            place(node)
            mergeNode = node
        }
        let mergeFrame = mergeNode?.frame ?? CGRect(x: mergeX, y: bandMid - 44, width: metrics.mergeWidth, height: 88)

        // After the merge: jobs with `needs` above the gate, the rest below.
        let postJobs = document.jobs.filter { $0.role.runsAfterMerge }
        let postX = mergeX + metrics.mergeWidth + metrics.columnGap + 10
        let above = postJobs.filter { !$0.needs.isEmpty }
        let below = postJobs.filter { $0.needs.isEmpty }
        for (index, job) in above.enumerated() {
            let nodeY = mergeFrame.minY - 26 - CGFloat(above.count - index) * (metrics.nodeHeight + metrics.rowGap)
            place(Node(id: job.id, kind: .job, label: job.name, family: job.family,
                       frame: CGRect(x: postX, y: nodeY, width: metrics.nodeWidth, height: metrics.nodeHeight), role: job.role, inputs: []))
        }
        for (index, job) in below.enumerated() {
            let nodeY = mergeFrame.maxY + 26 + CGFloat(index) * (metrics.nodeHeight + metrics.rowGap)
            place(Node(id: job.id, kind: .job, label: job.name, family: job.family,
                       frame: CGRect(x: postX, y: nodeY, width: metrics.nodeWidth, height: metrics.nodeHeight), role: job.role, inputs: []))
        }
        if !postJobs.isEmpty {
            let frames = postJobs.compactMap { placed[$0.id]?.frame } + [mergeFrame]
            let top = (frames.map(\.minY).min() ?? mergeFrame.minY) - metrics.laneHead - 6
            let bottom = (frames.map(\.maxY).max() ?? mergeFrame.maxY) + metrics.lanePadY
            lanes.append(Lane(
                id: "after-merge", kind: .afterMerge, label: "After the merge", question: "Push to main or a tag; never a pull request.",
                family: "release", frame: CGRect(x: postX - metrics.lanePadX, y: top, width: metrics.nodeWidth + metrics.lanePadX * 2, height: bottom - top),
                rail: bottom
            ))
        }

        // Manual band: jobs no event fires, started from the Actions tab.
        let manualJobs = document.jobs.filter { $0.role == .manual }
        var manualBottom = bandBottom
        if !manualJobs.isEmpty {
            let top = max(bandBottom, lanes.map(\.frame.maxY).max() ?? bandBottom) + metrics.laneGap + 8
            let laneHeight = metrics.laneHead + metrics.lanePadY + CGFloat(manualJobs.count) * metrics.nodeHeight
                + CGFloat(manualJobs.count - 1) * metrics.rowGap + metrics.lanePadY
            lanes.append(Lane(
                id: "manual", kind: .manual, label: "Manual", question: "Dispatched from the Actions tab; nothing in the pipeline waits on these.",
                family: "maintenance", frame: CGRect(x: jobsX0 - metrics.lanePadX, y: top, width: laneRight - (jobsX0 - metrics.lanePadX), height: laneHeight),
                rail: top + laneHeight - 10
            ))
            for (index, job) in manualJobs.enumerated() {
                let nodeY = top + metrics.laneHead + metrics.lanePadY + CGFloat(index) * (metrics.nodeHeight + metrics.rowGap)
                place(Node(id: job.id, kind: .job, label: job.name, family: job.family,
                           frame: CGRect(x: jobsX0, y: nodeY, width: metrics.nodeWidth, height: metrics.nodeHeight), role: job.role, inputs: []))
            }
            place(Node(id: manualTriggerID, kind: .trigger, label: "workflow_dispatch", family: "trigger",
                       frame: CGRect(x: metrics.margin, y: top + laneHeight / 2 - 27, width: metrics.triggerWidth, height: 54), role: nil, inputs: []))
            manualBottom = top + laneHeight
        }

        // Wires: orthogonal paths from a source pin to a target pin.
        let trunkInput = metrics.margin + metrics.triggerWidth + metrics.columnGap / 2
        let trunkMerge = mergeX - metrics.columnGap / 2 - 6
        var pinY: [String: CGFloat] = [:]
        if let mergeNode {
            let inputs = mergeNode.inputs
            let spacing = inputs.count > 1 ? (mergeNode.frame.height - 26) / CGFloat(inputs.count - 1) : 0
            for (index, id) in inputs.enumerated() {
                pinY[id] = mergeNode.frame.minY + 13 + CGFloat(index) * spacing
            }
        }
        let laneByID = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var wires: [Wire] = []
        for (index, wire) in document.wires.enumerated() {
            guard let source = placed[wire.source], let target = placed[wire.target] else { continue }
            let start = CGPoint(x: source.frame.maxX, y: source.frame.midY)
            let targetY = target.frame.midY
            var points: [CGPoint]
            var labelAt: CGPoint?
            switch wire.kind {
            case .trigger:
                points = [start, CGPoint(x: trunkInput, y: start.y), CGPoint(x: trunkInput, y: targetY), CGPoint(x: target.frame.minX, y: targetY)]
            case .gates:
                let gapX = source.frame.maxX + 24
                let railY = source.role != nil ? (laneByID[jobsByID[source.id]?.workflow ?? ""]?.rail ?? start.y) : start.y
                let pin = pinY[wire.source] ?? targetY
                points = [start, CGPoint(x: gapX, y: start.y), CGPoint(x: gapX, y: railY), CGPoint(x: trunkMerge, y: railY),
                          CGPoint(x: trunkMerge, y: pin), CGPoint(x: target.frame.minX, y: pin)]
            case .release:
                let outX = source.frame.maxX + 34
                points = [start, CGPoint(x: outX, y: start.y), CGPoint(x: outX, y: targetY), CGPoint(x: target.frame.minX, y: targetY)]
            case .artifact:
                let gapX = source.frame.maxX + 40
                points = [CGPoint(x: start.x, y: start.y + 9), CGPoint(x: gapX, y: start.y + 9), CGPoint(x: gapX, y: targetY + 9),
                          CGPoint(x: target.frame.minX, y: targetY + 9)]
                labelAt = CGPoint(x: (gapX + target.frame.minX) / 2, y: targetY + 5)
            case .needs, .custom:
                let gapX = source.frame.maxX + 24
                points = [start, CGPoint(x: gapX, y: start.y), CGPoint(x: gapX, y: targetY), CGPoint(x: target.frame.minX, y: targetY)]
            }
            wires.append(Wire(id: "\(index):\(wire.source)→\(wire.target)", source: wire.source, target: wire.target, kind: wire.kind,
                              label: wire.label, points: points, labelAt: labelAt))
        }

        let rightEdge = max(nodes.map(\.frame.maxX).max() ?? 0, lanes.map(\.frame.maxX).max() ?? 0) + metrics.margin
        let bottomEdge = max(manualBottom, lanes.map(\.frame.maxY).max() ?? 0, nodes.map(\.frame.maxY).max() ?? 0) + metrics.margin
        return ArchitectureGatesLayout(nodes: nodes, lanes: lanes, wires: wires, size: CGSize(width: rightEdge, height: bottomEdge))
    }
}
