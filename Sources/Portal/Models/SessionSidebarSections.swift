import Foundation

/// The sidebar's tiers, split in ONE pass over the session list and sorted
/// once per tier.
///
/// These used to be four computed properties on the sidebar view, each
/// re-filtering and re-sorting the whole session list per render, and later one
/// partition per render — which is still a sort of every session on every body
/// evaluation. The sidebar's body runs whenever its parent re-renders (every
/// streamed delta), so with a thousand sessions that was a main-thread storm.
/// `SessionListViewModel` now computes this once per change to its sessions
/// and hands the cached value to the view.
///
/// The tiers are deliberately NOT mutually exclusive: an owned cron session
/// shows under both "My Sessions" and "Cron Sessions", which is what the four
/// separate predicates did.
internal struct SessionSidebarSections: Equatable {
    internal var mine: [Session] = []
    internal var archived: [Session] = []
    internal var cron: [Session] = []
    internal var other: [Session] = []

    /// Partition `sessions` into tiers, sorting each with `sort` (four sorts,
    /// one per tier). Pure: the caller decides when it is worth recomputing.
    nonisolated internal static func partition(
        _ sessions: [Session],
        includes: (Session) -> Bool,
        sort: ([Session]) -> [Session]
    ) -> SessionSidebarSections {
        var sections = SessionSidebarSections()
        for session in sessions where includes(session) {
            let isCron = session.source?.caseInsensitiveCompare("cron") == .orderedSame
            if session.isOwned {
                if session.isArchived {
                    sections.archived.append(session)
                } else {
                    sections.mine.append(session)
                }
            } else if !isCron {
                sections.other.append(session)
            }
            if isCron { sections.cron.append(session) }
        }
        sections.mine = sort(sections.mine)
        sections.archived = sort(sections.archived)
        sections.cron = sort(sections.cron)
        sections.other = sort(sections.other)
        return sections
    }
}
