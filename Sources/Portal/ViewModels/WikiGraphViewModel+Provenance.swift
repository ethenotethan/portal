import Foundation

/// Navigating the provenance graph: page ⇄ changeset ⇄ event.
///
/// Both directions live here because they're one relationship read from two
/// ends, and reading them side by side is how you see that they stay inverse.
/// Split from the view model's own file so it keeps to its size limit — the
/// same reason `+EventTypes` is separate.
@MainActor
extension WikiGraphViewModel {

    /// Event → page. A changed-page chip (or a directive's target page) on the
    /// events page: leave the events surface, make the page the shared current
    /// page, and open the reader over the graph — the same landing as every
    /// other "jump into the wiki" path.
    internal func openPageLeavingEvents(_ path: String) {
        showEventsPage = false
        navigate(to: path)
        openReaderForSelection()
    }

    /// Changeset → event. A provenance chip: open the event feed positioned on
    /// the event that caused the change, closing the changeset drawer since the
    /// events page owns the whole surface and a drawer left open underneath
    /// would fight it.
    internal func openEventFeed(eventKey: String) {
        focusedEventKey = eventKey
        showTimeline = false
        showEventsPage = true
    }
}
