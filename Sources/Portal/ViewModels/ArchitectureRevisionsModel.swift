import Foundation
import Combine

/// Drives the Revisions tab for one service: the stored revisions
/// (`architecture.history`), the selected one, and the structural diff
/// (`architecture.diff`) between it and the revision before it, or between any
/// pair the reader picks. Viewing the map at a revision is the surface's job
/// (`ArchitectureSurfaceModel.load(revision:)`); this model only chooses.
@MainActor
internal final class ArchitectureRevisionsModel: ObservableObject {
    /// The counts that moved between two summaries, for the timeline chips.
    internal struct Delta: Hashable {
        internal let nodes: Int
        internal let edges: Int
        internal let files: Int
        internal let lines: Int
        internal let invariantsViolated: Int

        internal var isEmpty: Bool { nodes == 0 && edges == 0 && files == 0 && lines == 0 && invariantsViolated == 0 }

        internal static func between(_ before: ArchitectureModelSummary, _ after: ArchitectureModelSummary) -> Delta {
            Delta(
                nodes: after.nodes - before.nodes,
                edges: after.edges - before.edges,
                files: after.files - before.files,
                lines: after.lines - before.lines,
                invariantsViolated: after.violated.count - before.violated.count
            )
        }
    }

    @Published internal private(set) var history: ArchitectureRevisionHistory = .empty
    @Published internal private(set) var selectedRevision: String?
    /// The older side of the diff when the reader chose one; nil means "the previous revision".
    @Published internal private(set) var fromOverride: String?
    @Published internal private(set) var diff: ArchitectureRevisionDiff?
    @Published internal private(set) var isLoadingHistory = false
    @Published internal private(set) var isLoadingDiff = false
    @Published internal private(set) var errorMessage: String?
    @Published internal private(set) var diffMessage: String?

    private let service: String
    private let reader: any ArchitectureReading
    private var historyGeneration = 0
    private var diffGeneration = 0

    internal init(service: String, reader: any ArchitectureReading) {
        self.service = service
        self.reader = reader
    }

    /// Revisions newest first, for the timeline.
    internal var timeline: [ArchitectureRevisionEntry] { history.newestFirst }

    internal var selectedEntry: ArchitectureRevisionEntry? {
        selectedRevision.flatMap(history.entry)
    }

    /// The older revision the diff compares against: the override, else the previous stored one.
    internal var fromRevision: String? {
        if let fromOverride { return fromOverride }
        guard let selectedRevision else { return nil }
        return history.previous(of: selectedRevision)?.revision
    }

    /// The summary counts that moved from the previous revision to `entry`.
    internal func delta(for entry: ArchitectureRevisionEntry) -> Delta? {
        guard let previous = history.previous(of: entry.revision) else { return nil }
        return Delta.between(previous.summary, entry.summary)
    }

    internal func load() async {
        historyGeneration += 1
        let generation = historyGeneration
        isLoadingHistory = true
        errorMessage = nil
        defer { if generation == historyGeneration { isLoadingHistory = false } }
        do {
            let fetched = try await reader.architectureHistory(service: service, limit: nil)
            guard generation == historyGeneration else { return }
            history = fetched
            if selectedRevision == nil || fetched.entry(selectedRevision ?? "") == nil {
                selectedRevision = fetched.latest.isEmpty ? fetched.newestFirst.first?.revision : fetched.latest
            }
            await loadDiff()
        } catch {
            guard generation == historyGeneration else { return }
            errorMessage = ArchitectureSurfaceModel.friendly(error)
        }
    }

    internal func select(revision: String) async {
        guard revision != selectedRevision, history.entry(revision) != nil else { return }
        selectedRevision = revision
        if fromOverride == revision { fromOverride = nil }
        await loadDiff()
    }

    /// Choose the older side of the diff explicitly (nil returns to "previous").
    internal func setFrom(revision: String?) async {
        guard revision != fromOverride else { return }
        if let revision, history.entry(revision) == nil { return }
        fromOverride = revision == selectedRevision ? nil : revision
        await loadDiff()
    }

    internal func loadDiff() async {
        guard let to = selectedRevision else {
            diff = nil
            return
        }
        guard let from = fromRevision else {
            diff = nil
            diffMessage = "Earliest stored revision — nothing older to compare against"
            return
        }
        diffGeneration += 1
        let generation = diffGeneration
        isLoadingDiff = true
        diffMessage = nil
        defer { if generation == diffGeneration { isLoadingDiff = false } }
        do {
            let fetched = try await reader.architectureDiff(service: service, from: from, to: to)
            guard generation == diffGeneration else { return }
            diff = fetched
        } catch {
            guard generation == diffGeneration else { return }
            diff = nil
            diffMessage = ArchitectureSurfaceModel.friendly(error)
        }
    }
}
