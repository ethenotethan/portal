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

    // MARK: - Local Storage

    private static let titlesKey = "hermes.sessionTitles"

    /// Mapping: database-format ID → short hex gateway ID.
    /// Stored in UserDefaults so it persists across app launches.
    /// For "My Sessions", this lets us find the correct RPC session_id.
    private static let gatewayIDMapKey = "hermes.gatewayIDMap"

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
            for i in fetched.indices {
                // Merge local title (overrides gateway title)
                if let local = titles[fetched[i].id], !local.isEmpty {
                    fetched[i].localTitle = local
                }
                // Merge gateway ID mapping (for RPCs)
                if let gwID = idMap[fetched[i].id] {
                    fetched[i].gatewayID = gwID
                }
            }

            // Preserve sessions that are owned (have gatewayID) but whose
            // short hex ID hasn't been mapped to a database-format ID yet,
            // so they wouldn't appear in the fetched list.
            let fetchedIDs = Set(fetched.map { $0.id })
            let ownedUnmapped = sessions.filter { session in
                session.isOwned && !fetchedIDs.contains(session.id)
            }

            sessions = fetched + ownedUnmapped
        } catch {
            // Silently fail — session list is non-critical
        }
        isLoading = false
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
                        if self.activeSessionID == shortHexID {
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

        withAnimation {
            sessions.removeAll { $0.id == id }
        }
        if activeSessionID == id {
            activeSessionID = sessions.first?.id
        }
    }

    /// Set the active session (local selection only).
    func selectSession(id: String) {
        withAnimation {
            activeSessionID = id
        }
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
