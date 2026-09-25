import SwiftUI

/// The native CI gates renderer for the `ci` section of the contract: every
/// job drawn as a logic gate, the input signal on the left, `needs` and
/// artifact hand-offs as wires, every guarding job feeding one AND gate (the
/// merge), post-merge jobs downstream and manual jobs in their own band; then,
/// beneath the circuit, what the gates defend: ratchets, architectural checks
/// and static compiler checks.
@MainActor
internal struct ArchitectureGatesSectionView: View {
    internal let document: ArchitectureModelDocument
    @State private var selectedID: String?
    private let gates: ArchitectureGatesDocument?
    private let layout: ArchitectureGatesLayout

    internal init(document: ArchitectureModelDocument) {
        self.document = document
        let decoded = ArchitectureGatesDocument.decode(document.section(.ci))
        gates = decoded
        layout = decoded.map { ArchitectureGatesLayout.layout($0) } ?? .empty
    }

    internal var body: some View {
        if let gates {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    stats(gates)
                    circuit
                    legend(gates)
                    if let selectedID, let node = layout.node(selectedID) {
                        inspector(node, gates: gates)
                    }
                    ratchets(gates)
                    architectural(gates.architectural)
                    staticChecks(gates)
                    bulletList("What the diagram does not prove", gates.limitations)
                }
                .padding(18)
            }
        } else {
            ArchitectureSectionPlaceholder(
                icon: ArchitectureSurfaceTab.gates.icon,
                title: "No CI gates in this model",
                detail: "The document has no `ci` section with jobs; the hermes.architecture contract requires one, so this model is non-conforming."
            )
        }
    }

    // MARK: Stats

    private func stats(_ gates: ArchitectureGatesDocument) -> some View {
        let summary = gates.summary
        let tiles: [(value: String, label: String)] = [
            ("\(summary.workflows)", "Workflows"),
            ("\(summary.gates)", "PR gates"),
            ("\(summary.ratchets)", "Ratchets"),
            ("\(summary.architecturalChecks)", "Arch. checks"),
            ("\(summary.staticChecks)", "Static checks")
        ]
        return HStack(spacing: 28) {
            ForEach(tiles, id: \.label) { tile in
                VStack(alignment: .leading, spacing: 5) {
                    Text(tile.value)
                        .font(.system(size: 20, weight: .medium, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.primary)
                    Text(tile.label.uppercased())
                        .font(.system(size: 9, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                }
            }
            Spacer()
            if selectedID != nil {
                Button("Reset selection") { selectedID = nil }
                    .portalButton(prominent: false, size: .small)
            }
        }
    }

    // MARK: Circuit

    private var connected: Set<String> {
        selectedID.map(layout.connected(to:)) ?? []
    }

    private var circuit: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    drawLanes(in: &context)
                    drawWires(in: &context)
                }
                ForEach(layout.nodes) { node in
                    nodeView(node)
                        .frame(width: node.frame.width, height: node.frame.height)
                        .position(node.center)
                }
            }
            .frame(width: layout.size.width, height: layout.size.height)
        }
        .frame(minHeight: min(layout.size.height, 640))
        .background(Theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func drawLanes(in context: inout GraphicsContext) {
        for lane in layout.lanes {
            let path = Path(roundedRect: lane.frame, cornerRadius: 6)
            context.stroke(path, with: .color(Theme.border), style: StrokeStyle(lineWidth: 1, dash: lane.kind == .gates ? [] : [4, 4]))
            let title = Text(lane.label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
            context.draw(title, at: CGPoint(x: lane.frame.minX + 10, y: lane.frame.minY + 12), anchor: .leading)
            if !lane.question.isEmpty && lane.frame.width > 320 {
                let question = Text(lane.question)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.tertiary)
                context.draw(question, at: CGPoint(x: lane.frame.minX + 10, y: lane.frame.minY + 25), anchor: .leading)
            }
        }
    }

    private func drawWires(in context: inout GraphicsContext) {
        let highlighted = connected
        for wire in layout.wires {
            guard let first = wire.points.first else { continue }
            var path = Path()
            path.move(to: first)
            for point in wire.points.dropFirst() {
                path.addLine(to: point)
            }
            let lit = selectedID != nil && highlighted.contains(wire.source) && highlighted.contains(wire.target)
            let color: Color = lit ? Theme.accent : Theme.border
            let dashed = wire.kind == .artifact || wire.kind == .release
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lit ? 1.8 : 1, dash: dashed ? [5, 4] : []))
            if lit, let label = wire.label, let at = wire.labelAt {
                let text = Text(label)
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.accent)
                context.draw(text, at: at, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func nodeView(_ node: ArchitectureGatesLayout.Node) -> some View {
        let isSelected = node.id == selectedID
        let isDimmed = selectedID != nil && !connected.contains(node.id)
        Button {
            selectedID = isSelected ? nil : node.id
        } label: {
            switch node.kind {
            case .merge:
                mergeLabel(node, selected: isSelected)
            case .trigger:
                triggerLabel(node, selected: isSelected)
            case .job:
                jobLabel(node, selected: isSelected)
            }
        }
        .buttonStyle(.plain)
        .opacity(isDimmed ? 0.35 : 1)
        .help(node.id)
    }

    private func jobLabel(_ node: ArchitectureGatesLayout.Node, selected: Bool) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Self.familyColor(node.family)).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Text("\(node.family) · \(node.role?.rawValue ?? "job")")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 0)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
        .opacity(node.role == .disabled ? 0.55 : 1)
    }

    private func triggerLabel(_ node: ArchitectureGatesLayout.Node, selected: Bool) -> some View {
        Text(node.label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.primary)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.accent.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(selected ? Theme.accent : Theme.accent.opacity(0.5), lineWidth: selected ? 1.5 : 1))
    }

    private func mergeLabel(_ node: ArchitectureGatesLayout.Node, selected: Bool) -> some View {
        ZStack {
            ANDGateShape()
                .fill(Theme.success.opacity(0.12))
            ANDGateShape()
                .stroke(selected ? Theme.accent : Theme.success, lineWidth: selected ? 1.5 : 1)
            VStack(spacing: 4) {
                Text("AND")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .monospaced()
                Text("\(node.inputs.count) inputs")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.primary)
            .padding(.leading, 8)
        }
    }

    private func legend(_ gates: ArchitectureGatesDocument) -> some View {
        let families = ArchitectureGatesLayout.familyOrder.filter { family in gates.workflows.contains { $0.family == family } }
        return HStack(spacing: 16) {
            ForEach(families, id: \.self) { family in
                HStack(spacing: 6) {
                    Rectangle().fill(Self.familyColor(family)).frame(width: 14, height: 3)
                    Text(gates.families[family].map { "\(family) · \($0)" } ?? family)
                        .font(.system(size: 9, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                }
            }
            HStack(spacing: 6) {
                Rectangle().fill(Theme.border).frame(width: 14, height: 1)
                Text("needs · artifact (dashed) · gate → merge")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }

    // MARK: Inspector

    private func inspector(_ node: ArchitectureGatesLayout.Node, gates: ArchitectureGatesDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(node.kind == .merge ? "MERGE · AND" : node.kind == .trigger ? "TRIGGER" : node.family.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Self.familyColor(node.family))
                Spacer()
                Button("Close") { selectedID = nil }
                    .portalButton(prominent: false, size: .small)
            }
            Text(node.label)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            switch node.kind {
            case .merge:
                mergeInspector(node, gates: gates)
            case .trigger:
                triggerInspector(node, gates: gates)
            case .job:
                if let job = gates.job(node.id) {
                    jobInspector(job, gates: gates)
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func mergeInspector(_ node: ArchitectureGatesLayout.Node, gates: ArchitectureGatesDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(node.inputs.count) jobs run on every pull request. All of them must pass for the change to be mergeable; a red gate anywhere "
                + "holds the signal. GitHub's required-checks list is repository configuration and is not read here, so this is the set of "
                + "gates that run, not a proof of which are required.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            sectionTitle("Inputs")
            chipRow(node.inputs.map { id in (id: id, label: gates.job(id)?.name ?? id) })
        }
    }

    private func triggerInspector(_ node: ArchitectureGatesLayout.Node, gates: ArchitectureGatesDocument) -> some View {
        let trigger = gates.triggers.first { $0.id == node.id }
        return VStack(alignment: .leading, spacing: 8) {
            Text(node.id == ArchitectureGatesLayout.manualTriggerID
                ? "Started by hand from the Actions tab. Nothing in the pipeline waits on these jobs, so they are drawn in their own band."
                : "A pull request against main is the input signal. Every workflow listening to it starts its root jobs; a job whose "
                    + "condition excludes pull requests is drawn after the merge instead.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            if let trigger, !trigger.workflows.isEmpty {
                sectionTitle("Workflows listening")
                Text(trigger.workflows.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.primary)
            }
        }
    }

    private func jobInspector(_ job: ArchitectureGateJob, gates: ArchitectureGatesDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let evidence = job.evidence {
                let workflow = gates.workflowsByID[job.workflow]
                Text("\(evidence.display) · \(workflow?.name ?? job.workflow) · runs on \(job.runsOn.isEmpty ? "?" : job.runsOn) · role \(job.role.rawValue)")
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.secondary)
            }
            if let condition = job.condition {
                Text("if: \(condition)")
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.warning)
            }
            if !job.needs.isEmpty {
                sectionTitle("Needs")
                chipRow(job.needs.map { id in (id: id, label: gates.job(id)?.name ?? id) })
            }
            if !job.artifactsIn.isEmpty || !job.artifactsOut.isEmpty {
                sectionTitle("Artifacts")
                Text("in: \(job.artifactsIn.isEmpty ? "—" : job.artifactsIn.joined(separator: ", ")) · out: "
                    + (job.artifactsOut.isEmpty ? "—" : job.artifactsOut.joined(separator: ", ")))
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.primary)
            }
            if !job.pins.isEmpty {
                sectionTitle("Pins")
                Text(job.pins.map(\.display).joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.primary)
            }
            if !job.scripts.isEmpty {
                sectionTitle("Scripts")
                Text(job.scripts.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.primary)
            }
            sectionTitle("Steps (\(job.stepCount))")
            ForEach(Array(job.steps.enumerated()), id: \.offset) { _, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.name + (step.condition.map { " · if \($0)" } ?? ""))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.primary)
                    if let command = step.command ?? step.uses {
                        Text(command)
                            .font(.system(size: 10, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(3)
                    }
                }
            }
        }
    }

    // MARK: Beneath the circuit

    private func ratchets(_ gates: ArchitectureGatesDocument) -> some View {
        group("Ratchets", note: "\(gates.ratchets.count) metric gates. Each compares the tree against a committed baseline; the floor may only rise.") {
            ForEach(gates.ratchets) { ratchet in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ratchet.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                        jobLink(ratchet.job)
                        Spacer()
                        Text(ratchet.currentSummary)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.primary)
                    }
                    Text(ratchet.measures)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                    Text("Floor: \(ratchet.floor)" + (ratchet.patch.map { " · Patch: \($0)" } ?? ""))
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                    if !ratchet.breakdown.isEmpty {
                        chipRow(ratchet.breakdown.map { (id: "\(ratchet.id):\($0.key)", label: "\($0.key) \($0.value)") }, selectable: false)
                    }
                }
                .padding(.vertical, 6)
                Divider().background(Theme.border)
            }
        }
    }

    private func architectural(_ checks: ArchitectureArchitecturalChecks) -> some View {
        group("Architectural checks", note: "\(checks.lintRules.count) custom SwiftLint rules, \(checks.tests.count) architecture tests and "
            + "\(checks.invariants.count) compiler invariants pin the shape of the code. They run in \(checks.runsIn.joined(separator: ", ")).") {
            bulletList("SwiftLint rules" + (checks.lintConfig.map { " · \($0)" } ?? ""), checks.lintRules.map { rule in
                "\(rule.id) (\(rule.severity)) — \(rule.message)" + (rule.baselined > 0 ? " · \(rule.baselined) baselined" : "")
            })
            bulletList("Architecture tests" + (checks.testsPath.map { " · \($0)" } ?? ""), checks.tests.map(\.title))
            bulletList("Invariants", checks.invariants.map { "\($0.id) · \($0.status) — \($0.why)" })
        }
    }

    private func staticChecks(_ gates: ArchitectureGatesDocument) -> some View {
        group("Static compiler checks", note: "\(gates.staticChecks.count) checks that recompile a committed artifact and fail on drift between it and the tree.") {
            ForEach(gates.staticChecks) { check in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(check.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                        jobLink(check.job)
                    }
                    Text(check.command)
                        .font(.system(size: 10, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.secondary)
                    if let evidence = check.evidence {
                        Text(evidence.display)
                            .font(.system(size: 9, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.tertiary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: Building blocks

    private func group<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
            Text(note)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.tertiary)
    }

    /// A job's id as a link that selects it in the circuit.
    private func jobLink(_ jobID: String) -> some View {
        Button(jobID) { selectedID = jobID }
            .buttonStyle(.plain)
            .font(.system(size: 9, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.accent)
    }

    private func bulletList(_ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle(title)
            if items.isEmpty {
                Text("None declared.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(Theme.tertiary)
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Chips naming jobs (selectable) or plain values, wrapping as the width allows.
    private func chipRow(_ items: [(id: String, label: String)], selectable: Bool = true) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button(item.label) {
                    if selectable { selectedID = item.id }
                }
                .buttonStyle(.plain)
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(selectable ? Theme.accent : Theme.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border, lineWidth: 1))
            }
        }
    }

    private static let familyHex: [String: String] = [
        "behavior": "70b98d", "posture": "e7a84b", "build": "5ca8d8", "publication": "8b83ff",
        "release": "d16f86", "maintenance": "8d8a88", "trigger": "8b83ff", "merge": "70b98d"
    ]

    internal static func familyColor(_ family: String) -> Color {
        familyHex[family].flatMap { Color(hex: $0) } ?? Theme.secondary
    }
}

/// The classic AND-gate outline: a flat left side that takes the input pins, a
/// semicircular right side that carries the output.
internal struct ANDGateShape: Shape {
    internal func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.height / 2
        let flatRight = max(rect.minX, rect.maxX - radius)
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: flatRight, y: rect.minY))
        path.addArc(center: CGPoint(x: flatRight, y: rect.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
