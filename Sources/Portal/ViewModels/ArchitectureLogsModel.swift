import Foundation
import Combine

/// Drives the Logs tab for one service: which declared sink is shown, its tail
/// (`architecture.logs`), the lines appended since (by cursor or, while
/// following, by `architecture.log` events), and a filter over the buffer.
/// The buffer is bounded so a chatty service cannot grow memory without limit.
@MainActor
internal final class ArchitectureLogsModel: ObservableObject {
    internal static let tailLines = 500
    internal static let maxBufferedLines = 5_000

    @Published internal private(set) var sinks: [ArchitectureLogSink]
    @Published internal private(set) var selectedSinkID: String?
    @Published internal private(set) var lines: [String] = []
    @Published internal private(set) var cursor = ""
    @Published internal private(set) var truncated = false
    @Published internal private(set) var isLoading = false
    @Published internal private(set) var isFollowing = false
    @Published internal private(set) var errorMessage: String?
    @Published internal private(set) var statusMessage: String?
    @Published internal var filter = ""

    private let service: String
    private let reader: any ArchitectureReading
    private var cancellables: Set<AnyCancellable> = []
    /// Drop-stale guard: a slow older load must not overwrite a newer one.
    private var loadGeneration = 0

    internal init(service: String, sinks: [ArchitectureLogSink], reader: any ArchitectureReading) {
        self.service = service
        self.reader = reader
        self.sinks = sinks
        self.selectedSinkID = sinks.first?.id
        reader.architectureEvents
            .sink { [weak self] event in
                guard case .architectureLog(let payload) = event else { return }
                self?.handle(payload)
            }
            .store(in: &cancellables)
    }

    internal var selectedSink: ArchitectureLogSink? {
        sinks.first { $0.id == selectedSinkID }
    }

    /// The buffer narrowed by the filter, case-insensitively.
    internal var filteredLines: [String] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.lowercased().contains(needle) }
    }

    /// Load the tail of the selected sink, replacing the buffer.
    internal func load() async {
        guard let sinkID = selectedSinkID else {
            errorMessage = "This service declares no log sink."
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let tail = try await reader.architectureLogs(service: service, sink: sinkID, lines: Self.tailLines, cursor: nil)
            guard generation == loadGeneration else { return }
            apply(tail, replacing: true)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = ArchitectureSurfaceModel.friendly(error)
        }
    }

    /// Fetch what was appended since the cursor (the manual refresh while not following).
    internal func fetchMore() async {
        guard let sinkID = selectedSinkID, !cursor.isEmpty else {
            await load()
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let tail = try await reader.architectureLogs(service: service, sink: sinkID, lines: Self.tailLines, cursor: cursor)
            guard generation == loadGeneration else { return }
            apply(tail, replacing: tail.rotated)
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = ArchitectureSurfaceModel.friendly(error)
        }
    }

    /// Switch sinks: stop following the old one, load the new one's tail.
    internal func select(sinkID: String) async {
        guard sinkID != selectedSinkID, sinks.contains(where: { $0.id == sinkID }) else { return }
        if isFollowing { await setFollowing(false) }
        selectedSinkID = sinkID
        lines = []
        cursor = ""
        truncated = false
        statusMessage = nil
        await load()
    }

    internal func toggleFollow() async {
        await setFollowing(!isFollowing)
    }

    internal func setFollowing(_ enabled: Bool) async {
        guard let sinkID = selectedSinkID, enabled != isFollowing else { return }
        do {
            let state = try await reader.architectureLogsFollow(service: service, sink: sinkID, enabled: enabled)
            isFollowing = state.following
            if state.following, !state.cursor.isEmpty { cursor = state.cursor }
            statusMessage = state.following ? "Following \(selectedSink?.displayLabel ?? sinkID)" : nil
        } catch {
            isFollowing = false
            errorMessage = ArchitectureSurfaceModel.friendly(error)
        }
    }

    /// Stop following when the tab goes away; the gateway would time out on
    /// its own after ten idle minutes, but there is no reason to make it wait.
    internal func teardown() async {
        if isFollowing { await setFollowing(false) }
        cancellables.removeAll()
    }

    /// A followed sink's event: append its lines, restart on rotation, and
    /// report when the gateway ended the follow.
    internal func handle(_ event: ArchitectureLogEvent) {
        guard event.service == service, event.sink == selectedSinkID else { return }
        if let stopped = event.stopped {
            isFollowing = false
            statusMessage = stopped == "idle-timeout" ? "Follow stopped after ten idle minutes" : "Follow stopped: \(stopped)"
            return
        }
        if event.rotated {
            statusMessage = "Log rotated · tail restarted"
            lines = []
        }
        append(event.lines)
        if !event.cursor.isEmpty { cursor = event.cursor }
    }

    private func apply(_ tail: ArchitectureLogTail, replacing: Bool) {
        if !tail.sinks.isEmpty {
            sinks = tail.sinks
        }
        if replacing {
            lines = []
        }
        if tail.rotated {
            statusMessage = "Log rotated · tail restarted"
        }
        append(tail.lines)
        cursor = tail.cursor
        truncated = tail.truncated
    }

    private func append(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxBufferedLines {
            lines.removeFirst(lines.count - Self.maxBufferedLines)
        }
    }
}
