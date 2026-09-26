import SwiftUI

/// The Revisions tab: every stored revision of the service's model as a
/// timeline (newest first) with the commit behind it and what moved, and the
/// structural diff between the selected revision and the one before it, or any
/// pair the reader picks. "View map at this revision" swaps the surface's
/// document for that snapshot.
@MainActor
internal struct ArchitectureRevisionsSectionView: View {
    @StateObject private var model: ArchitectureRevisionsModel
    @ObservedObject private var surface: ArchitectureSurfaceModel

    internal init(service: String, reader: any ArchitectureReading, surface: ArchitectureSurfaceModel) {
        _model = StateObject(wrappedValue: ArchitectureRevisionsModel(service: service, reader: reader))
        _surface = ObservedObject(wrappedValue: surface)
    }

    internal var body: some View {
        HStack(spacing: 0) {
            timeline
                .frame(width: 360)
            Divider().background(Theme.border)
            diffPanel
        }
        .background(Theme.background)
        .task { await model.load() }
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.timeline.count) stored revisions")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if let runtime = model.history.runtime {
                    Text(runtimeCaption(runtime))
                        .font(.system(size: 10, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .help("The runtime this model is bound to")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider().background(Theme.border)
            if let message = model.errorMessage {
                emptyState(icon: "exclamationmark.triangle", title: "History unavailable", detail: message)
            } else if model.isLoadingHistory, model.timeline.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.timeline) { entry in
                            timelineRow(entry)
                        }
                    }
                }
            }
        }
    }

    private func runtimeCaption(_ runtime: ArchitectureRuntimeInfo) -> String {
        var parts = [runtime.provider.isEmpty ? runtime.graphID : runtime.provider]
        if let started = runtime.startedAt, !started.isEmpty { parts.append("up since \(started)") }
        if let pid = runtime.pid { parts.append("pid \(pid)") }
        return parts.joined(separator: " · ")
    }

    private func timelineRow(_ entry: ArchitectureRevisionEntry) -> some View {
        let selected = entry.revision == model.selectedRevision
        let isFrom = entry.revision == model.fromRevision
        return Button {
            Task { await model.select(revision: entry.revision) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 0) {
                    Circle()
                        .fill(entry.deployed ? Theme.success : (selected ? Theme.accent : Theme.border))
                        .frame(width: 9, height: 9)
                        .padding(.top, 5)
                    Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(entry.shortRevision)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.primary)
                        if entry.deployed {
                            pill("DEPLOYED", color: Theme.success)
                                .help(entry.deployedAt.map { "The checkout is at this revision · stored \($0)" } ?? "The checkout is at this revision")
                        }
                        if isFrom, !selected {
                            pill("FROM", color: Theme.accent).help("The older side of the diff")
                        }
                        if let check = entry.check {
                            pill(check.status.uppercased(), color: check.passed ? Theme.success : (check.ran ? Theme.warning : Theme.secondary))
                                .help(check.detail)
                        }
                    }
                    Text(entry.storedAt.isEmpty ? entry.source : entry.storedAt)
                        .font(.system(size: 10, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                    if let commit = entry.commit {
                        Text(commit.subject)
                            .font(.caption)
                            .foregroundStyle(Theme.primary)
                            .lineLimit(2)
                        Text(commit.author.isEmpty ? commit.shortSHA : "\(commit.author) · \(commit.shortSHA)")
                            .font(.system(size: 10, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.tertiary)
                    }
                    if let delta = model.delta(for: entry), !delta.isEmpty {
                        deltaChips(delta)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Theme.surface : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Compare from here") { Task { await model.setFrom(revision: entry.revision) } }
            Button("Compare with previous") { Task { await model.setFrom(revision: nil) } }
        }
    }

    private func deltaChips(_ delta: ArchitectureRevisionsModel.Delta) -> some View {
        HStack(spacing: 4) {
            if delta.nodes != 0 { chip(signed(delta.nodes), "nodes") }
            if delta.edges != 0 { chip(signed(delta.edges), "edges") }
            if delta.files != 0 { chip(signed(delta.files), "files") }
            if delta.lines != 0 { chip(signed(delta.lines), "lines") }
            if delta.invariantsViolated != 0 { chip(signed(delta.invariantsViolated), "violated") }
        }
    }

    private func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "−\(-value)" }

    private func chip(_ value: String, _ label: String) -> some View {
        Text("\(value) \(label)")
            .font(.system(size: 9, design: .monospaced))
            .monospaced()
            .foregroundStyle(value.hasPrefix("+") ? Theme.success : Theme.warning)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 3))
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .monospaced()
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    // MARK: Diff panel

    @ViewBuilder
    private var diffPanel: some View {
        if let entry = model.selectedEntry {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    diffHeader(entry)
                    if model.isLoadingDiff {
                        ProgressView()
                    } else if let diff = model.diff {
                        diffBody(diff)
                    } else if let message = model.diffMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            emptyState(icon: "clock.arrow.circlepath", title: "No revision selected", detail: "Pick a revision in the timeline.")
        }
    }

    private func diffHeader(_ entry: ArchitectureRevisionEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Revision \(entry.shortRevision)")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button(surface.revision == entry.revision ? "Viewing this revision" : "View map at this revision") {
                    Task { await surface.load(revision: entry.revision) }
                }
                .portalButton(prominent: false, size: .small)
                .disabled(surface.revision == entry.revision)
                .help("Swap every tab to this stored snapshot")
            }
            HStack(spacing: 8) {
                Text("Compared with")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                Picker("From", selection: Binding(
                    get: { model.fromRevision ?? "" },
                    set: { value in Task { await model.setFrom(revision: value.isEmpty ? nil : value) } }
                )) {
                    ForEach(model.timeline.filter { $0.revision != entry.revision }) { other in
                        Text(other.shortRevision).tag(other.revision)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
                if model.fromOverride != nil {
                    Button("Previous") { Task { await model.setFrom(revision: nil) } }
                        .portalButton(prominent: false, size: .small)
                }
            }
            if let diff = model.diff {
                Text(diff.headline)
                    .font(.system(size: 11, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder
    private func diffBody(_ diff: ArchitectureRevisionDiff) -> some View {
        if diff.isEmpty {
            Text("No structural change between these revisions.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
        }
        if !diff.nodesAdded.isEmpty || !diff.nodesRemoved.isEmpty {
            section("Constructions") {
                nodeGroups(diff.nodesAdded, sign: "+", color: Theme.success)
                nodeGroups(diff.nodesRemoved, sign: "−", color: Theme.warning)
            }
        }
        if !diff.edgesAdded.isEmpty || !diff.edgesRemoved.isEmpty {
            section("Edges") {
                ForEach(diff.edgesAdded) { edge in monoRow("+ \(edge.source) —\(edge.relation)→ \(edge.target)", color: Theme.success) }
                ForEach(diff.edgesRemoved) { edge in monoRow("− \(edge.source) —\(edge.relation)→ \(edge.target)", color: Theme.warning) }
            }
        }
        if !diff.invariantsAdded.isEmpty || !diff.invariantsRemoved.isEmpty || !diff.invariantsChanged.isEmpty {
            section("Invariants") {
                ForEach(diff.invariantsAdded, id: \.self) { id in monoRow("+ \(id)", color: Theme.success) }
                ForEach(diff.invariantsRemoved, id: \.self) { id in monoRow("− \(id)", color: Theme.warning) }
                ForEach(diff.invariantsChanged) { change in
                    monoRow("\(change.id): \(change.from) → \(change.to)", color: change.to == "holds" ? Theme.success : Theme.warning)
                }
            }
        }
        if !diff.filesAdded.isEmpty || !diff.filesRemoved.isEmpty || !diff.filesChanged.isEmpty {
            section("Files") {
                ForEach(diff.filesAdded, id: \.self) { path in monoRow("+ \(path)", color: Theme.success) }
                ForEach(diff.filesRemoved, id: \.self) { path in monoRow("− \(path)", color: Theme.warning) }
                ForEach(diff.filesChanged) { file in
                    monoRow("\(file.path)  \(signed(file.delta)) lines (\(file.linesFrom) → \(file.linesTo))", color: Theme.primary)
                }
            }
        }
        if !diff.gates.isEmpty {
            section("Gates") {
                ForEach(diff.gates.jobsAdded, id: \.self) { id in monoRow("+ job \(id)", color: Theme.success) }
                ForEach(diff.gates.jobsRemoved, id: \.self) { id in monoRow("− job \(id)", color: Theme.warning) }
                ForEach(diff.gates.ratchetsAdded, id: \.self) { id in monoRow("+ ratchet \(id)", color: Theme.success) }
                ForEach(diff.gates.ratchetsRemoved, id: \.self) { id in monoRow("− ratchet \(id)", color: Theme.warning) }
            }
        }
        if let git = diff.git {
            section("Code changes") {
                if git.commits.isEmpty, git.stat.isEmpty {
                    Text("No commits between the two revisions in the checkout.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(git.commits) { commit in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(commit.subject)
                            .font(.caption)
                            .foregroundStyle(Theme.primary)
                        Text("\(commit.shortSHA) · \(commit.author) · \(commit.date)")
                            .font(.system(size: 10, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                if !git.stat.isEmpty {
                    Text("\(git.stat.count) file(s) · +\(git.additions) −\(git.deletions)\(git.truncated ? " · list truncated" : "")")
                        .font(.system(size: 10, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                        .padding(.top, 4)
                    ForEach(git.stat) { stat in
                        monoRow(
                            stat.isBinary ? "\(stat.path)  binary" : "\(stat.path)  +\(stat.additions ?? 0) −\(stat.deletions ?? 0)",
                            color: Theme.primary
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func nodeGroups(_ changes: [ArchitectureRevisionDiff.NodeChange], sign: String, color: Color) -> some View {
        ForEach(ArchitectureRevisionDiff.byKind(changes), id: \.kind) { group in
            Text(group.kind.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
                .padding(.top, 4)
            ForEach(group.nodes) { node in
                monoRow("\(sign) \(node.label)\(node.component.map { "  (\($0))" } ?? "")", color: color)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    private func monoRow(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .monospaced()
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
