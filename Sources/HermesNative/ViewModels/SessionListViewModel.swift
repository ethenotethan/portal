import Foundation
import Combine
import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SessionListViewModel")

/// Manages the list of sessions and session creation/resumption/killing.
/// Tracks the mapping between database IDs (from session.list) and
/// gateway in-memory IDs (short hex, from session.create) so RPCs work.
@MainActor
final class SessionListViewModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var activeSessionID: String?
    @Published var isLoading: Bool = false
    var isSuppressingSelectionHandler = false

    private var gatewayClient: GatewayClient?
    private var cancellables = Set<AnyCancellable>()

    /// Guards against overlapping timer-driven refreshes: if one refresh takes
    /// longer than the poll interval, new invocations are skipped, and a
    /// generation token ensures a slow older fetch can't overwrite the list
    /// after a newer one already committed.
    private var isRefreshInFlight = false
    private var refreshGeneration = 0

    /// Client-observed live run states keyed by stable database ID or runtime
    /// gateway ID. The gateway's `session.list` response may not include live
    /// run state yet, so the native app updates this from its own prompt/event
    /// stream to keep sidebar icons current.
    private var localRunStates: [String: SessionRunState] = [:]

    /// Wired up by ContentView — refreshes cron jobs alongside sessions.
    var cronViewModel: CronListViewModel?

    /// Cross-device sync of titles/pins/archives/tags via the gateway KV store.
    private let metaSync = SessionMetaSyncService()
    /// Per-session last-modified stamps for sync merge (session ID → date).
    private var metaUpdatedAt: [String: Date] = [:]
    private static let metaUpdatedAtKey = "hermes.sessionMetaUpdatedAt"

    // MARK: - Local Storage (Coalesced UserDefaults)

    /// All UserDefaults writes are batched through a 500ms coalesced flush
    /// timer. On iOS, individual UserDefaults.set() calls saturate the
    /// CFPreferences daemon and cause main-thread stalls. The coalesced
    /// pattern updates in-memory backing stores immediately and flushes
    /// to disk on a timer, collapsing rapid mutations into one write cycle.

    private static let titlesKey = "hermes.sessionTitles"
    private static let gatewayIDMapKey = "hermes.gatewayIDMap"
    private static let archivedIDsKey = "hermes.archivedSessions"
    private static let pinnedIDsKey = "hermes.pinnedSessions"
    private static let tagsKey = "hermes.sessionTags"

    // ── In-memory backing stores ──
    private var _gatewayIDMap: [String: String] = [:]
    private var _localTitles: [String: String] = [:]
    private var _archivedIDs: Set<String> = []
    private var _pinnedIDs: Set<String> = []
    private var _sessionTags: [String: [String]] = [:]

    // ── Coalesced flush plumbing ──
    private var defaultsDirty = false
    private var defaultsFlushTask: Task<Void, Never>?

    // ── Public accessors (in-memory reads, coalesced writes) ──

    private var gatewayIDMap: [String: String] {
        get { _gatewayIDMap }
        set { _gatewayIDMap = newValue; scheduleDefaultsFlush() }
    }

    private var localTitles: [String: String] {
        get { _localTitles }
        set { _localTitles = newValue; scheduleDefaultsFlush() }
    }

    private var archivedIDs: Set<String> {
        get { _archivedIDs }
        set { _archivedIDs = newValue; scheduleDefaultsFlush() }
    }

    private var pinnedIDs: Set<String> {
        get { _pinnedIDs }
        set { _pinnedIDs = newValue; scheduleDefaultsFlush() }
    }

    private var sessionTags: [String: [String]] {
        get { _sessionTags }
        set { _sessionTags = newValue; scheduleDefaultsFlush() }
    }

    /// Whether the "Archived" section is expanded.
    @Published var showArchived: Bool = false

    // MARK: - Init

    init() {
        loadFromUserDefaults()
    }

    // MARK: - UserDefaults Flush

    private func loadFromUserDefaults() {
        _gatewayIDMap = (UserDefaults.standard.dictionary(forKey: Self.gatewayIDMapKey) as? [String: String]) ?? [:]
        _localTitles = (UserDefaults.standard.dictionary(forKey: Self.titlesKey) as? [String: String]) ?? [:]
        _archivedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.archivedIDsKey) ?? [])
        _pinnedIDs = Set(UserDefaults.standard.stringArray(forKey: Self.pinnedIDsKey) ?? [])
        _sessionTags = (UserDefaults.standard.dictionary(forKey: Self.tagsKey) as? [String: [String]]) ?? [:]
        if let stamps = UserDefaults.standard.dictionary(forKey: Self.metaUpdatedAtKey) as? [String: Double] {
            metaUpdatedAt = stamps.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    private func scheduleDefaultsFlush() {
        defaultsDirty = true
        guard defaultsFlushTask == nil else { return }
        defaultsFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            guard let self, !Task.isCancelled, self.defaultsDirty else { return }
            await MainActor.run { self.flushDefaultsNow() }
        }
    }

    private func flushDefaultsNow() {
        defaultsFlushTask?.cancel()
        defaultsFlushTask = nil
        guard defaultsDirty else { return }
        defaultsDirty = false
        UserDefaults.standard.set(_gatewayIDMap, forKey: Self.gatewayIDMapKey)
        UserDefaults.standard.set(_localTitles, forKey: Self.titlesKey)
        UserDefaults.standard.set(Array(_archivedIDs), forKey: Self.archivedIDsKey)
        UserDefaults.standard.set(Array(_pinnedIDs), forKey: Self.pinnedIDsKey)
        UserDefaults.standard.set(_sessionTags, forKey: Self.tagsKey)
        UserDefaults.standard.set(
            metaUpdatedAt.mapValues { $0.timeIntervalSince1970 },
            forKey: Self.metaUpdatedAtKey
        )
    }

    // MARK: - Cross-Device Metadata Sync

    /// Stamp a session as locally modified and schedule a debounced push.
    private func touchMeta(_ sessionID: String) {
        metaUpdatedAt[sessionID] = Date()
        scheduleDefaultsFlush()
        metaSync.schedulePush { [weak self] in
            self?.buildMetaDocument() ?? SessionMetaSyncService.Document()
        }
    }

    private func buildMetaDocument() -> SessionMetaSyncService.Document {
        var doc = SessionMetaSyncService.Document()
        doc.deviceID = SessionMetaSyncService.deviceID
        var ids = Set(_localTitles.keys)
        ids.formUnion(_pinnedIDs)
        ids.formUnion(_archivedIDs)
        ids.formUnion(_sessionTags.keys)
        for id in ids {
            doc.entries[id] = SessionMetaSyncService.Entry(
                customTitle: _localTitles[id],
                pinned: _pinnedIDs.contains(id),
                archived: _archivedIDs.contains(id),
                tags: _sessionTags[id] ?? [],
                updatedAt: metaUpdatedAt[id] ?? .distantPast
            )
        }
        return doc
    }

    /// Pull the remote metadata document (throttled) and merge: newer entry
    /// per session wins. Pushes back when local entries were newer.
    private func syncMetaIfDue() async {
        guard let remote = await metaSync.pullIfDue() else { return }
        let (merged, localHadNewer) = SessionMetaSyncService.merge(
            local: buildMetaDocument(), remote: remote)

        var changed = false
        for (id, entry) in merged.entries {
            let remoteWon = remote.entries[id].map { $0.updatedAt > (metaUpdatedAt[id] ?? .distantPast) } ?? false
            guard remoteWon else { continue }
            changed = true
            metaUpdatedAt[id] = entry.updatedAt
            if let title = entry.customTitle, !title.isEmpty {
                _localTitles[id] = title
            } else {
                _localTitles.removeValue(forKey: id)
            }
            if entry.pinned { _pinnedIDs.insert(id) } else { _pinnedIDs.remove(id) }
            if entry.archived { _archivedIDs.insert(id) } else { _archivedIDs.remove(id) }
            if entry.tags.isEmpty {
                _sessionTags.removeValue(forKey: id)
            } else {
                _sessionTags[id] = entry.tags
            }
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                sessions[idx].localTitle = entry.customTitle
                sessions[idx].isPinned = entry.pinned
                sessions[idx].isArchived = entry.archived
                sessions[idx].tags = entry.tags
            }
        }
        if changed { scheduleDefaultsFlush() }
        if localHadNewer { await metaSync.push(buildMetaDocument()) }
    }

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
        // 4. Local chat history — extract first user message as title
        if let firstUser = ChatHistoryStore.shared.firstUserMessage(forSession: session.id) {
            let title = String(firstUser.prefix(60)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
        }
        // 5. Short ID
        return session.id.prefix(8).description
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
        touchMeta(id)
    }

    // MARK: - Gateway

    func setGatewayClient(_ client: GatewayClient) {
        gatewayClient = client
        metaSync.setClient(client)
    }

    /// Clear the in-memory session list when switching gateways. The new
    /// gateway has its own sessions; a `refreshSessions()` after reconnect
    /// repopulates the list.
    func resetForGatewaySwitch() {
        cancellables.removeAll()
        gatewayClient = nil
        sessions = []
        activeSessionID = nil
        isLoading = false
        localRunStates.removeAll()
        refreshGeneration += 1
        isRefreshInFlight = false
    }

    /// Refresh the session list from the gateway, merging local data.
    /// Preserves sessions that are owned (have gatewayID) but haven't been
    /// discovered in the gateway's session.list yet (their short hex ID
    /// hasn't been mapped to a database-format ID).
    func refreshSessions() async {
        await refreshSessions(refreshCron: true)
    }

    func refreshSessions(refreshCron: Bool) async {
        guard let client = gatewayClient else { return }
        // Skip if a refresh is already running (3s poll timer can stack
        // invocations when the gateway is slow).
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        defer { isRefreshInFlight = false }
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        do {
            var fetched = try await client.listSessions()
            // Stale-completion guard: a newer refresh committed while this one
            // was awaiting — don't overwrite its result.
            guard generation == refreshGeneration else {
                isLoading = false
                return
            }
            // Merge cross-device metadata before applying local overlays, so
            // a rename/pin made on another device lands in this refresh.
            // Throttled internally to one pull per ~10s despite the 3s poll.
            await syncMetaIfDue()
            guard generation == refreshGeneration else {
                isLoading = false
                return
            }
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
            let fetchedGatewayIDs = Set(fetched.compactMap { $0.gatewayID })
            let ownedUnmapped = sessions.filter { session in
                session.isOwned
                    && !fetchedIDs.contains(session.id)
                    && !fetchedGatewayIDs.contains(session.gatewayID ?? "")
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
                } else if SessionBackendRegistry.shared.backendID(for: id) != nil {
                    // Session-scoped (Centaur) session restored from disk:
                    // the thread key IS the runtime ID, and the registry
                    // proves this app created it. Without this it demotes
                    // to "not owned" after every restart and falls out of
                    // My Sessions.
                    session.gatewayID = id
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
        if refreshCron, let cronVM = cronViewModel {
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
        session.lastActive = Date()
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
                        // If the database-format ID already exists (from a concurrent
                        // refreshSessions), remove the short-hex "owned unmapped" entry
                        // to avoid duplicate ForEach identities.
                        if self.sessions.contains(where: { $0.id == dbID }) {
                            self.sessions.removeAll { $0.id == shortHexID || $0.gatewayID == shortHexID }
                            self.storeGatewayIDMapping(databaseID: dbID, gatewayID: shortHexID)
                            if self.activeSessionID == shortHexID {
                                self.activeSessionID = dbID
                            }
                            return
                        }
                        // Update the session's primary ID to the database format
                        if let idx = self.sessions.firstIndex(where: { $0.gatewayID == shortHexID }) {
                            let oldID = self.sessions[idx].id
                            var updated = self.sessions[idx]
                            updated.id = dbID
                            self.migrateLocalOrganizationState(from: oldID, to: dbID)
                            self.migrateLocalRunState(from: oldID, to: dbID, gatewayID: shortHexID)
                            updated.runState = self.localRunStates[dbID] ?? updated.runState
                            updated.isPinned = self.pinnedIDs.contains(dbID)
                            updated.tags = self.sessionTags[dbID] ?? []
                            if let title = self.localTitles[oldID] {
                                var titles = self.localTitles
                                titles[dbID] = title
                                titles.removeValue(forKey: oldID)
                                self.localTitles = titles
                                updated.localTitle = title
                            }
                            self.sessions[idx] = updated
                        }
                        self.storeGatewayIDMapping(databaseID: dbID, gatewayID: shortHexID)
                        if self.activeSessionID == shortHexID, self.sessions.contains(where: { $0.id == dbID }) {
                            self.isSuppressingSelectionHandler = true
                            self.activeSessionID = dbID
                        }
                        return  // Success — done
                    }
                } catch {
                    log.error("session.title attempt \(attempt + 1) failed: \(error)")
                }
                // Wait before retry (agent may still be initializing)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            log.error("session.title gave up after 3 attempts for \(shortHexID)")
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
        // Clean up local data — mutate backing stores directly, then flush
        _localTitles.removeValue(forKey: id)
        _gatewayIDMap.removeValue(forKey: id)
        _archivedIDs.remove(id)
        _pinnedIDs.remove(id)
        _sessionTags.removeValue(forKey: id)
        localRunStates.removeValue(forKey: id)
        if let gatewayID = sessions.first(where: { $0.id == id })?.gatewayID {
            localRunStates.removeValue(forKey: gatewayID)
        }
        flushDefaultsNow()

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
        touchMeta(id)

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
        touchMeta(id)

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
        touchMeta(id)

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
        touchMeta(id)

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
            _archivedIDs.remove(id)
            _localTitles.removeValue(forKey: id)
            flushDefaultsNow()

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
