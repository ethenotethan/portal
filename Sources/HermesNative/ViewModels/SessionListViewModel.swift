import Foundation
import Combine
import SwiftUI

/// Manages the list of sessions and session creation/resumption/killing.
/// Tracks the mapping between database IDs (from session.list) and
/// gateway in-memory IDs (short hex, from session.create) so RPCs work.
@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String?
    @Published var isLoading: Bool = false

    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    /// Client-observed live run states keyed by stable database ID or runtime
    /// gateway ID. The gateway's `session.list` response may not include live
    /// run state yet, so the native app updates this from its own prompt/event
    /// stream to keep sidebar icons current.
    private var localRunStates: [String: SessionRunState] = [:]

    /// Wired up by ContentView — refreshes cron jobs alongside sessions.
    var cronViewModel: CronListViewModel?

    // MARK: - Local Storage

    private static let titlesKey = "hermes.sessionTitles"

    /// Mapping: database-format ID → short hex gateway ID.
    /// Stored in UserDefaults so it persists across app launches.
    /// For "My Sessions", this lets us find the correct RPC session_id.
    private static let gatewayIDMapKey = "hermes.gatewayIDMap"

    /// Set of database-format IDs that are archived.
    private static let archivedIDsKey = "hermes.archivedSessions"

    /// Set of database-format IDs pinned to the top of their section.
    private static let pinnedIDsKey = "hermes.pinnedSessions"

    /// Mapping: database-format ID → lightweight local tags.
    private static let tagsKey = "hermes.sessionTags"

    private var gatewayIDMap: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.gatewayIDMapKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.gatewayIDMapKey) }
    }

    /// Client-side titles keyed by database ID. Persisted to UserDefaults.
    /// Overrides gateway title when present (user has chatted in-app).
    private var localTitles: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.titlesKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.titlesKey) }
    }

    /// Archived session IDs — persisted to UserDefaults.
    private var archivedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.archivedIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.archivedIDsKey) }
    }

    /// Pinned session IDs — persisted to UserDefaults.
    private var pinnedIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.pinnedIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.pinnedIDsKey) }
    }

    /// Tags keyed by session ID — persisted to UserDefaults.
    private var sessionTags: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: Self.tagsKey) as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.tagsKey) }
    }

    /// Whether the "Archived" section is expanded.
    @Published var showArchived: Bool = false

    /// Get the display title for a session.
    /// Priority: local title (from first user message) > gateway title > preview (truncated) > source > short ID.
    func titleForSession(_ session: Session) -> String {
        // 1. Local title from first user message (highest priority)
        if let local = localTitles[session.id], !local.isEmpty {
            return local
        }
        // 2. Gateway-provided title
        if let title = session.title, !title.isEmpty {
            return title
        }
        // 3. Preview (truncated to 50 chars)
        if let preview = session.preview, !preview.isEmpty {
            return String(preview.prefix(50)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 4. Source-based fallback
        if let source = session.source, !source.isEmpty {
            return "\(source) session"
        }
        // 5. Short ID
        return "Session \(session.id.prefix(8))"
    }

    /// Get the subtitle for a session (second line info).
    func subtitleForSession(_ session: Session) -> String? {
        var parts: [String] = []
        if let source = session.source, !source.isEmpty {
            parts.append(source)
        }
        if session.messageCount > 0 {
            parts.append("\(session.messageCount) msgs")
        }
        if let date = session.startedAt {
            parts.append(date.relativeString)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Owned sessions are rendered with the native app skin, even though the
    /// gateway persists them with source="tui" because they run through the TUI
    /// agent backend. Show the visible skin here so the Sessions list matches
    /// the actual chat pane.
    func subtitleForOwnedSession(_ session: Session, skin: ChatSkin) -> String? {
        var parts: [String] = [skin.displayName]
        if session.messageCount > 0 {
            parts.append("\(session.messageCount) msgs")
        }
        if let date = session.startedAt {
            parts.append(date.relativeString)
        }
        return parts.joined(separator: " · ")
    }

    /// Store the mapping from database ID to gateway short hex ID.
    func storeGatewayIDMapping(databaseID: String, gatewayID: String) {
        var map = gatewayIDMap
        map[databaseID] = gatewayID
        gatewayIDMap = map

        // Also update the session in the list if it exists
        if let idx = sessions.firstIndex(where: { $0.id == databaseID }) {
            sessions[idx].gatewayID = gatewayID
        }
    }

    /// Get the gateway short hex ID for a database ID, if we have one.
    func gatewayIDForSession(databaseID: String) -> String? {
        gatewayIDMap[databaseID]
    }

    /// Store a title for a session (called when first user message is sent).
    func updateSessionTitle(id: String, title: String) {
        var titles = localTitles
        titles[id] = title
        localTitles = titles

        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].localTitle = title
        }
    }

    // MARK: - Gateway

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
    }

    /// Refresh the session list from the gateway, merging local data.
    /// Preserves sessions that are owned (have gatewayID) but haven't been
    /// discovered in the gateway's session.list yet (their short hex ID
    /// hasn't been mapped to a database-format ID).
    func refreshSessions() async {
        guard let client = gatewayClient else { return }
        isLoading = true
        do {
            var fetched = try await client.listSessions()
            let titles = localTitles
            let idMap = gatewayIDMap
            let archived = archivedIDs
            let pinned = pinnedIDs
            let tags = sessionTags
            let runStates = localRunStates
            for i in fetched.indices {
                // Merge local title (overrides gateway title)
                if let local = titles[fetched[i].id], !local.isEmpty {
                    fetched[i].localTitle = local
                }
                // Merge gateway ID mapping (for RPCs)
                if let gwID = idMap[fetched[i].id] {
                    fetched[i].gatewayID = gwID
                }
                // Merge local organization state
                fetched[i].isArchived = archived.contains(fetched[i].id)
                fetched[i].isPinned = pinned.contains(fetched[i].id)
                fetched[i].tags = tags[fetched[i].id] ?? []
                let mappedGatewayID = idMap[fetched[i].id]
                let localRunState = runStates[fetched[i].id]
                    ?? mappedGatewayID.flatMap { runStates[$0] }
                if let localRunState {
                    fetched[i].runState = localRunState
                }
            }

            // Preserve sessions that are owned (have gatewayID) but whose
            // short hex ID hasn't been mapped to a database-format ID yet,
            // so they wouldn't appear in the fetched list.
            let fetchedIDs = Set(fetched.map { $0.id })
            let ownedUnmapped = sessions.filter { session in
                session.isOwned && !fetchedIDs.contains(session.id)
            }

            // Preserve sessions that have local history on disk but are no
            // longer returned by the gateway (gateway restart, session expiry,
            // etc.). These still appear in the sidebar so the user can read
            // their history and never loses data.
            let localOnlyIDs = ChatHistoryStore.shared.localSessionIDs()
            let localOnlySessions: [Session] = localOnlyIDs.compactMap { id in
                guard !fetchedIDs.contains(id),
                      !ownedUnmapped.contains(where: { $0.id == id }) else { return nil }
                var session = Session(id: id, messageCount: 0)
                if let gwID = gatewayIDMap[id] {
                    session.gatewayID = gwID
                }
                if let local = titles[id], !local.isEmpty {
                    session.localTitle = local
                }
                session.isArchived = archived.contains(id)
                session.isPinned = pinned.contains(id)
                session.tags = tags[id] ?? []
                return session
            }

            sessions = fetched + ownedUnmapped + localOnlySessions
        } catch {
            // Silently fail — session list is non-critical
        }
        isLoading = false

        // Refresh cron jobs if a cron view model is wired up
        if let cronVM = cronViewModel {
            await cronVM.refreshJobs()
        }
    }

    /// Register a session created by this app (short hex ID from session.create).
    /// Adds it to the list immediately with `gatewayID` set so it appears in "My Sessions",
    /// then fires an async task to discover the database-format ID via `session.title`.
    func registerOwnedSession(shortHexID: String) {
        // Don't add if already present
        guard !sessions.contains(where: { $0.id == shortHexID || $0.gatewayID == shortHexID }) else {
            activeSessionID = shortHexID
            return
        }
        var session = Session(id: shortHexID, messageCount: 0)
        session.gatewayID = shortHexID
        session.runState = .queued
        localRunStates[shortHexID] = .queued
        sessions.append(session)
        activeSessionID = shortHexID

        // Async: discover the database-format ID via session.title and store the mapping.
        // Retries up to 3 times because the agent may still be initializing.
        Task { [weak self] in
            guard let self, let client = self.gatewayClient else { return }
            for attempt in 0..<3 {
                do {
                    let result = try await client.sessionTitle(sessionID: shortHexID)
                    if let dbID = result.sessionKey, !dbID.isEmpty, dbID != shortHexID {
                        // Update the session's primary ID to the database format
                        if let idx = self.sessions.firstIndex(where: { $0.gatewayID == shortHexID }) {
                            let oldID = self.sessions[idx].id
                            self.sessions[idx].id = dbID
                            self.migrateLocalOrganizationState(from: oldID, to: dbID)
                            self.migrateLocalRunState(from: oldID, to: dbID, gatewayID: shortHexID)
                            self.sessions[idx].runState = self.localRunStates[dbID] ?? self.sessions[idx].runState
                            self.sessions[idx].isPinned = self.pinnedIDs.contains(dbID)
                            self.sessions[idx].tags = self.sessionTags[dbID] ?? []
                            // Move local title if needed
                            if let title = self.localTitles[oldID] {
                                var titles = self.localTitles
                                titles[dbID] = title
                                titles.removeValue(forKey: oldID)
                                self.localTitles = titles
                                self.sessions[idx].localTitle = title
                            }
                        }
                        self.storeGatewayIDMapping(databaseID: dbID, gatewayID: shortHexID)
                        if self.activeSessionID == shortHexID, self.sessions.contains(where: { $0.id == dbID }) {
                            self.activeSessionID = dbID
                        }
                        return  // Success — done
                    }
                } catch {
                    NSLog("[HermesNative] session.title attempt \(attempt + 1) failed: \(error)")
                }
                // Wait before retry (agent may still be initializing)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            NSLog("[HermesNative] session.title gave up after 3 attempts for \(shortHexID)")
        }
    }

    /// Create a new session and set it as active.
    func createSession() async throws -> String {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }

        let shortHexID = try await client.createSession()
        registerOwnedSession(shortHexID: shortHexID)
        return shortHexID
    }

    /// Resume an existing session by its database ID + gateway ID.
    /// Returns the gateway short hex ID on success.
    @discardableResult
    func resumeSession(_ session: Session) async throws -> String? {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }
        guard session.isOwned else {
            // Not our session — can't resume
            return nil
        }
        // resumeSession expects the database-format ID as session_id
        let result = try await client.resumeSession(key: session.id)
        activeSessionID = session.id

        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx].isRunning = true
        }
        return result.sessionID
    }

    /// Close (kill) a session by its database ID.
    func closeSession(id: String) async throws {
        guard let client = gatewayClient else {
            throw GatewayError.notConnected
        }
        // Use the gateway ID (short hex) for the close RPC
        let rpcID = sessions.first(where: { $0.id == id })?.rpcID ?? id
        try await client.closeSession(sessionID: rpcID)
        // Clean up local history file
        ChatHistoryStore.shared.deleteMessages(forSession: id)
        // Clean up local data
        var titles = localTitles
        titles.removeValue(forKey: id)
        localTitles = titles
        var idMap = gatewayIDMap
        idMap.removeValue(forKey: id)
        gatewayIDMap = idMap
        // Remove local organization state too
        var archived = archivedIDs
        archived.remove(id)
        archivedIDs = archived
        var pinned = pinnedIDs
        pinned.remove(id)
        pinnedIDs = pinned
        var tags = sessionTags
        tags.removeValue(forKey: id)
        sessionTags = tags
        localRunStates.removeValue(forKey: id)
        if let gatewayID = sessions.first(where: { $0.id == id })?.gatewayID {
            localRunStates.removeValue(forKey: gatewayID)
        }

        withAnimation {
            sessions.removeAll { $0.id == id }
        }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
    }


    /// Update the best-known run state for a session row from live app events.
    /// Matches either stable database ID or runtime gateway ID so icons continue
    /// updating across the short-ID → stable-ID remap.
    func setRunState(_ runState: SessionRunState?, for id: String) {
        if let runState {
            localRunStates[id] = runState
        } else {
            localRunStates.removeValue(forKey: id)
        }

        for idx in sessions.indices where sessions[idx].id == id || sessions[idx].gatewayID == id {
            sessions[idx].runState = runState
            localRunStates[sessions[idx].id] = runState
            if let gatewayID = sessions[idx].gatewayID {
                localRunStates[gatewayID] = runState
            }
        }
    }

    func runState(for id: String) -> SessionRunState? {
        localRunStates[id]
            ?? sessions.first(where: { $0.id == id || $0.gatewayID == id })?.runState
    }


    /// Pin or unpin a session. Pinned rows are sorted to the top of each section.
    func setPinned(_ isPinned: Bool, for id: String) {
        var pinned = pinnedIDs
        if isPinned {
            pinned.insert(id)
        } else {
            pinned.remove(id)
        }
        pinnedIDs = pinned

        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].isPinned = isPinned
        }
    }

    func togglePinned(id: String) {
        setPinned(!pinnedIDs.contains(id), for: id)
    }

    /// Replace all local tags for a session. Tags are normalized to lowercase,
    /// trimmed, de-duplicated, and capped so the sidebar stays compact.
    func setTags(_ tags: [String], for id: String) {
        let normalized = Array(Set(tags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }.filter { !$0.isEmpty })).sorted().prefix(8)

        var allTags = sessionTags
        if normalized.isEmpty {
            allTags.removeValue(forKey: id)
        } else {
            allTags[id] = Array(normalized)
        }
        sessionTags = allTags

        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            sessions[idx].tags = Array(normalized)
        }
    }

    func addTag(_ tag: String, to id: String) {
        let current = sessionTags[id] ?? []
        setTags(current + [tag], for: id)
    }

    func removeTag(_ tag: String, from id: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        setTags((sessionTags[id] ?? []).filter { $0 != normalized }, for: id)
    }

    private func migrateLocalOrganizationState(from oldID: String, to newID: String) {
        guard oldID != newID else { return }

        var pinned = pinnedIDs
        if pinned.remove(oldID) != nil {
            pinned.insert(newID)
            pinnedIDs = pinned
        }

        var archived = archivedIDs
        if archived.remove(oldID) != nil {
            archived.insert(newID)
            archivedIDs = archived
        }

        var tags = sessionTags
        if let oldTags = tags.removeValue(forKey: oldID) {
            tags[newID] = oldTags
            sessionTags = tags
        }
    }


    private func migrateLocalRunState(from oldID: String, to newID: String, gatewayID: String?) {
        guard oldID != newID else { return }
        if let state = localRunStates[oldID] ?? gatewayID.flatMap({ localRunStates[$0] }) {
            localRunStates[newID] = state
            if let gatewayID { localRunStates[gatewayID] = state }
        }
        localRunStates.removeValue(forKey: oldID)
    }

    /// Shared sidebar sort: pinned first, then most recently active/started.
    func sortedForSidebar(_ sessions: [Session]) -> [Session] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            let lhsDate = lhs.lastActive ?? lhs.startedAt ?? .distantPast
            let rhsDate = rhs.lastActive ?? rhs.startedAt ?? .distantPast
            return lhsDate > rhsDate
        }
    }

    /// Archive a session — hides it from "My Sessions", shows in "Archived".
    func archiveSession(id: String) {
        var archived = archivedIDs
        archived.insert(id)
        archivedIDs = archived

        withAnimation {
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].isArchived = true
            }
        }
    }

    /// Unarchive a session — moves it back to "My Sessions".
    func unarchiveSession(id: String) {
        var archived = archivedIDs
        archived.remove(id)
        archivedIDs = archived

        withAnimation {
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].isArchived = false
            }
        }
    }

    /// Permanently delete an archived session (kills gateway + removes local data).
    func deleteArchivedSession(id: String) async throws {
        // If the session is still alive on the gateway, kill it
        if let session = sessions.first(where: { $0.id == id }), session.isOwned {
            try await closeSession(id: id)
        } else {
            // Not owned — just clean local data
            ChatHistoryStore.shared.deleteMessages(forSession: id)
            var archived = archivedIDs
            archived.remove(id)
            archivedIDs = archived
            var titles = localTitles
            titles.removeValue(forKey: id)
            localTitles = titles

            withAnimation {
                sessions.removeAll { $0.id == id }
            }
        }
    }

    /// Set the active session (local selection only).
    func selectSession(id: String) {
        activeSessionID = id
    }
}

// MARK: - Date Extension

extension Date {
    /// Human-readable relative time string (e.g. "2h ago", "Just now").
    var relativeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
