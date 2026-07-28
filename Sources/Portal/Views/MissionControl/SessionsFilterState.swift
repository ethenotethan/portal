import Foundation

/// Shared filter state for the sessions canvas. Owned by
/// `SessionsDashboardCanvas` and injected into every panel that either
/// drives or consumes the filter (search bar panel → list panel → timeline).
@MainActor
internal final class SessionsFilterState: ObservableObject {
    @Published internal var searchText = ""
    @Published internal var filterStatus: FilterStatus = .all
    @Published internal var filterSource: String?

    internal enum FilterStatus: String, CaseIterable {
        case all    = "All"
        case live   = "Live"
        case ended  = "Ended"
    }

    /// Apply status and source filters. Text search is intentionally excluded —
    /// panels that have access to the user-visible session title handle it themselves
    /// (title lookup needs `SessionListViewModel`).
    internal func filteredSessions(from sessions: [Session]) -> [Session] {
        var result = sessions
        switch filterStatus {
        case .all:   break
        case .live:  result = result.filter { $0.isLive }
        case .ended: result = result.filter { !$0.isLive }
        }
        if let src = filterSource {
            result = result.filter { $0.displaySource == src }
        }
        return result
    }
}
