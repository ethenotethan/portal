import Foundation
import Testing
@testable import Portal

/// The sidebar was a main-thread storm engine: it re-derived its tiers inside
/// `body` (twelve filter+sort passes per render) and answered "can this session
/// export?" with a blocking `fileExists` per row. These tests pin the cheap
/// replacements — the single-pass partition and the on-disk index.
@Suite("Sidebar render cost")
internal struct SidebarRenderCostTests {

    // MARK: - Partitioning the tiers in one pass

    private func session(
        _ id: String,
        gatewayID: String? = "gw",
        source: String? = nil,
        isArchived: Bool = false,
        isPinned: Bool = false,
        lastActive: Date? = nil
    ) -> Session {
        var session = Session(id: id, messageCount: 0)
        session.gatewayID = gatewayID
        session.source = source
        session.isArchived = isArchived
        session.isPinned = isPinned
        session.lastActive = lastActive
        return session
    }

    /// The same comparator the view model applies, so ordering is asserted
    /// against real behavior rather than identity.
    private func sortByRecency(_ sessions: [Session]) -> [Session] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return (lhs.lastActive ?? .distantPast) > (rhs.lastActive ?? .distantPast)
        }
    }

    private func partition(_ sessions: [Session], includes: (Session) -> Bool = { _ in true })
        -> SessionListView.SidebarSections {
        SessionListView.partition(sessions, includes: includes, sort: sortByRecency)
    }

    @Test("Owned, archived and foreign sessions land in their own tiers")
    internal func tiersSplitByOwnershipAndArchive() {
        let sections = partition([
            session("mine"),
            session("filed", isArchived: true),
            session("theirs", gatewayID: nil, source: "telegram")
        ])
        #expect(sections.mine.map(\.id) == ["mine"])
        #expect(sections.archived.map(\.id) == ["filed"])
        #expect(sections.other.map(\.id) == ["theirs"])
        #expect(sections.cron.isEmpty)
    }

    @Test("An owned cron session shows in both My Sessions and Cron Sessions")
    internal func ownedCronAppearsInBothTiers() {
        // The four predicates this replaced were not mutually exclusive, and the
        // sidebar has always double-listed owned cron runs. Keep it that way.
        let sections = partition([session("nightly", source: "cron")])
        #expect(sections.mine.map(\.id) == ["nightly"])
        #expect(sections.cron.map(\.id) == ["nightly"])
        #expect(sections.other.isEmpty)
    }

    @Test("A foreign cron session is a cron row only, never an Other row")
    internal func foreignCronIsNotAlsoOther() {
        let sections = partition([session("remote-cron", gatewayID: nil, source: "Cron")])
        #expect(sections.cron.map(\.id) == ["remote-cron"])
        #expect(sections.other.isEmpty)
    }

    @Test("The source match ignores case, as the lowercased comparison did")
    internal func cronMatchIsCaseInsensitive() {
        let sections = partition([
            session("a", gatewayID: nil, source: "CRON"),
            session("b", gatewayID: nil, source: "Cron"),
            session("c", gatewayID: nil, source: "cron")
        ])
        #expect(Set(sections.cron.map(\.id)) == ["a", "b", "c"])
    }

    @Test("Every tier comes out sorted, pinned first then most recent")
    internal func tiersAreSorted() {
        let sections = partition([
            session("old", lastActive: Date(timeIntervalSince1970: 10)),
            session("new", lastActive: Date(timeIntervalSince1970: 90)),
            session("pinned", isPinned: true, lastActive: Date(timeIntervalSince1970: 1))
        ])
        #expect(sections.mine.map(\.id) == ["pinned", "new", "old"])
    }

    @Test("A focused gateway's filter is applied once, before the split")
    internal func filterExcludesBeforeSplitting() {
        var probes = 0
        let sections = partition(
            [session("keep"), session("drop"), session("filed", isArchived: true)],
            includes: { probes += 1; return $0.id != "drop" }
        )
        #expect(sections.mine.map(\.id) == ["keep"])
        #expect(sections.archived.map(\.id) == ["filed"])
        // One probe per session — the point of the rewrite. The old code called
        // the filter 12x per session per render.
        #expect(probes == 3)
    }

    @Test("An empty session list yields four empty tiers, not nil")
    internal func emptyListIsEmptyTiers() {
        let sections = partition([])
        #expect(sections.mine.isEmpty)
        #expect(sections.archived.isEmpty)
        #expect(sections.cron.isEmpty)
        #expect(sections.other.isEmpty)
    }

    // MARK: - The local-history index

    @MainActor
    @Test("A session saved this run is known without waiting on the disk write")
    internal func savedSessionIsKnownImmediately() {
        let store = ChatHistoryStore.shared
        _ = store.localSessionIDs()
        let id = "index-save-\(UUID().uuidString)"
        #expect(store.hasLocalMessages(forSession: id) == false)

        store.saveMessages([ChatMessage(role: .user, content: "hi")], forSession: id)
        // The write itself is detached; the index is updated up front so the
        // sidebar does not have to stat the filesystem to find out.
        #expect(store.hasLocalMessages(forSession: id))

        store.deleteMessages(forSession: id)
        #expect(store.hasLocalMessages(forSession: id) == false)
    }

    @MainActor
    @Test("Listing the directory refreshes what the index believes")
    internal func listingRefreshesTheIndex() throws {
        let store = ChatHistoryStore.shared
        let dir = store.sessionsDirectoryForTesting
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = store.localSessionIDs()

        // Someone else — another device's sync, a previous run — drops a
        // transcript in after the index was built.
        let id = "index-refresh-\(UUID().uuidString)"
        let file = dir.appendingPathComponent("\(id).json")
        try Data("[]".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(store.hasLocalMessages(forSession: id) == false)
        #expect(store.localSessionIDs().contains(id))
        #expect(store.hasLocalMessages(forSession: id))
    }

    @MainActor
    @Test("A cold store answers from disk rather than reporting nothing")
    internal func coldStoreReadsDiskOnce() throws {
        let store = ChatHistoryStore.shared
        let dir = store.sessionsDirectoryForTesting
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = "index-cold-\(UUID().uuidString)"
        let file = dir.appendingPathComponent("\(id).json")
        try Data("[]".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(store.localSessionIDs().contains(id))
        #expect(store.hasLocalMessages(forSession: id))
    }

    // MARK: - The backend probe

    @MainActor
    @Test("With nothing bound, the backend probe short-circuits to nil")
    internal func emptyRegistryReportsNoBackend() {
        // The sidebar asks this once per session per render, and the keys are
        // UserDefaults-bridged NSStrings whose hashing is slow.
        #expect(SessionBackendRegistry.shared.backendID(for: "never-bound-\(UUID().uuidString)") == nil)
    }

    @MainActor
    @Test("A bound session still resolves to its backend, and forgetting clears it")
    internal func boundSessionResolves() {
        let registry = SessionBackendRegistry.shared
        let id = "bound-\(UUID().uuidString)"
        let backend = UUID()
        registry.bind(sessionID: id, backendID: backend)
        #expect(registry.backendID(for: id) == backend)
        #expect(registry.backendID(for: "other-\(UUID().uuidString)") == nil)

        registry.forget(sessionID: id)
        #expect(registry.backendID(for: id) == nil)
    }
}
