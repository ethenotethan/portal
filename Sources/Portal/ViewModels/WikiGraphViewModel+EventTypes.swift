import Foundation

/// Resolving the wiki's ingestion-source taxonomy — the `type: event-type`
/// pages that say what a trigger MEANS.
///
/// Lives beside the graph view model rather than inside it because the wiki
/// owns this vocabulary: a new ingestion source is a page someone commits, and
/// the client's job is only to read the declaration and draw it.
@MainActor
extension WikiGraphViewModel {

    /// Upper bound on definition pages read per load. A wiki declaring more
    /// than this has a lint problem, and the cap keeps a pathological (or
    /// hostile) wiki from turning one scan into hundreds of page fetches.
    internal static let eventTypePageLimit = 64

    /// Read the wiki's `type: event-type` pages and rebuild the registry.
    ///
    /// Definition pages come from the graph the scan already returned, so this
    /// only fetches the frontmatter `wiki.scan` doesn't carry (it returns a
    /// page's type and title, not arbitrary keys). A page that won't load is
    /// simply absent, leaving its kind derived — the same outcome as never
    /// declaring it, and not worth failing the surface over.
    ///
    /// Fetched serially rather than in a task group: `WikiSource` is a
    /// non-`Sendable` class (the Centaur client and the gateway are both
    /// main-actor bound), so handing it to concurrent child tasks is a data
    /// race the compiler correctly rejects. The cost is bounded by
    /// `eventTypePageLimit` round-trips off the critical path, since the graph
    /// is already painted and every kind resolves without this.
    internal func loadEventTypes(source: any WikiSource) async {
        let definitions = graph.pages
            .filter { $0.type == WikiEventTypeRegistry.definitionPageType }
            .prefix(Self.eventTypePageLimit)
        guard !definitions.isEmpty else {
            // A wiki that declared types and then deleted them must fall back
            // to derivation, so clear rather than keep a stale registry.
            if !eventTypes.isEmpty { eventTypes = .empty }
            return
        }

        let generation = currentLoadGeneration
        var fetched: [String: [String: String]] = [:]
        for page in definitions {
            // A wiki switch mid-walk makes the rest of these fetches answer
            // for the wrong wiki; drop out rather than publish a mixed registry.
            guard generation == currentLoadGeneration else { return }
            if let content = await loadPage(source: source, path: page.path) {
                fetched[page.path] = content.frontmatter
            }
        }
        guard generation == currentLoadGeneration else { return }

        eventTypes = WikiEventTypeRegistry.build(
            pages: graph.pages,
            frontmatter: { fetched[$0.path] ?? [:] }
        )
    }
}
