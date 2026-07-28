import Foundation

/// Global filter state for the sessions canvas. Owned by
/// `SessionsDashboardCanvas` and injected into every panel — search panel
/// drives it, list and timeline consume it. Cron sessions are always
/// excluded before any filter is applied.
@MainActor
internal final class SessionsFilterState: ObservableObject {
    @Published internal var searchText = ""
    @Published internal var filterStatus: FilterStatus = .all
    @Published internal var filterSource: String?
    @Published internal var timeWindow: TimeWindow = .all
    @Published internal var sortOrder: SortOrder = .recent
    @Published internal var displayMode: DisplayMode = .status
    @Published internal var selectedSessionID: String?
    @Published internal var savedPresets: [FilterPreset] = []

    internal init() {
        if let data = UserDefaults.standard.data(forKey: Self.presetsKey) {
            do {
                savedPresets = try JSONDecoder().decode([FilterPreset].self, from: data)
            } catch {
                savedPresets = []
            }
        }
    }

    // MARK: - Enums

    internal enum FilterStatus: String, CaseIterable, Codable {
        case all   = "All"
        case live  = "Live"
        case ended = "Ended"
    }

    internal enum TimeWindow: Codable, Equatable {
        case all
        case hour
        case day
        case week
        case month
        case since(Date)   // custom "on or after" date picked by the user

        internal static var presets: [TimeWindow] { [.all, .hour, .day, .week, .month] }

        internal var label: String {
            switch self {
            case .all:        return "All time"
            case .hour:       return "Last hour"
            case .day:        return "Last 24h"
            case .week:       return "Last 7d"
            case .month:      return "Last 30d"
            case .since(let d):
                let f = DateFormatter()
                f.dateStyle = .short
                f.timeStyle = .none
                return "Since \(f.string(from: d))"
            }
        }

        internal var isCustom: Bool {
            if case .since = self { return true }
            return false
        }

        internal var cutoff: Date? {
            let now = Date()
            switch self {
            case .all:          return nil
            case .hour:         return now.addingTimeInterval(-3_600)
            case .day:          return now.addingTimeInterval(-86_400)
            case .week:         return now.addingTimeInterval(-604_800)
            case .month:        return now.addingTimeInterval(-2_592_000)
            case .since(let d): return d
            }
        }
    }

    internal enum SortOrder: String, CaseIterable, Codable {
        case recent   = "Recent"
        case duration = "Duration"
        case messages = "Messages"
    }

    internal enum DisplayMode: String, CaseIterable, Codable {
        case status = "By Status"
        case source = "By Source"
    }

    // MARK: - Saved presets

    internal struct FilterPreset: Codable, Identifiable {
        internal let id: UUID
        internal var name: String
        internal var status: FilterStatus
        internal var source: String?
        internal var timeWindow: TimeWindow
        internal var searchText: String

        internal init(id: UUID = UUID(), name: String, status: FilterStatus,
                      source: String?, timeWindow: TimeWindow, searchText: String) {
            self.id = id
            self.name = name
            self.status = status
            self.source = source
            self.timeWindow = timeWindow
            self.searchText = searchText
        }
    }

    private static let presetsKey = "sessionsDashboardFilterPresets.v1"

    internal func saveCurrentPreset(name: String) {
        let preset = FilterPreset(name: name, status: filterStatus, source: filterSource,
                                  timeWindow: timeWindow, searchText: searchText)
        savedPresets.append(preset)
        persistPresets()
    }

    internal func applyPreset(_ preset: FilterPreset) {
        filterStatus = preset.status
        filterSource = preset.source
        timeWindow = preset.timeWindow
        searchText = preset.searchText
    }

    internal func deletePreset(id: UUID) {
        savedPresets.removeAll { $0.id == id }
        persistPresets()
    }

    private func persistPresets() {
        do {
            let data = try JSONEncoder().encode(savedPresets)
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        } catch {}
    }

    // MARK: - Filtering

    /// Apply all global filters. Cron sessions are stripped unconditionally.
    /// Text search is excluded here — panels that have the session title handle
    /// it themselves (title lookup needs `SessionListViewModel`).
    internal func filteredSessions(from sessions: [Session]) -> [Session] {
        var result = sessions.filter { !$0.isCron }
        switch filterStatus {
        case .all:   break
        case .live:  result = result.filter { $0.isLive }
        case .ended: result = result.filter { !$0.isLive }
        }
        if let src = filterSource {
            result = result.filter { $0.displaySource == src }
        }
        if let cutoff = timeWindow.cutoff {
            result = result.filter { s in
                (s.startedAt ?? s.lastActive ?? .distantPast) >= cutoff
            }
        }
        return result
    }

    /// Sort a pre-filtered session array according to `sortOrder`.
    internal func sorted(_ sessions: [Session]) -> [Session] {
        switch sortOrder {
        case .recent:
            return sessions.sorted {
                ($0.lastActive ?? $0.startedAt ?? .distantPast) >
                ($1.lastActive ?? $1.startedAt ?? .distantPast)
            }
        case .duration:
            return sessions.sorted {
                durationOf($0) > durationOf($1)
            }
        case .messages:
            return sessions.sorted { $0.messageCount > $1.messageCount }
        }
    }

    private func durationOf(_ s: Session) -> TimeInterval {
        guard let start = s.startedAt else { return 0 }
        let end = s.endedAt ?? s.lastActive ?? Date()
        return end.timeIntervalSince(start)
    }
}
