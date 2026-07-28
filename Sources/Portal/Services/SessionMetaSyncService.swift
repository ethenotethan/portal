import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "SessionMetaSync")

/// Syncs session organization metadata (custom titles, pinned, archived,
/// tags) across devices through the gateway's generic config KV store.
/// UserDefaults remains the local/offline source; this service merges a
/// remote document into it and pushes local changes back.
///
/// Merge is last-writer-wins PER SESSION ENTRY by `updatedAt`, so a Mac
/// pinning session A and an iPhone renaming session B both survive.
@MainActor
final class SessionMetaSyncService {

    struct Entry: Codable, Equatable {
        var customTitle: String?
        var pinned: Bool
        var archived: Bool
        var tags: [String]
        var updatedAt: Date
    }

    struct Document: Codable {
        var entries: [String: Entry] = [:]
        var deviceID: String = ""
    }

    static let configKey = "hermesnative.sessionMeta"

    private weak var client: GatewayClient?
    /// nil = unknown (not yet probed); false = gateway lacks config.* support.
    private var syncAvailable: Bool?
    private var lastPullAt: Date?
    private var pushTask: Task<Void, Never>?
    private var pendingPush = false

    private let minPullInterval: TimeInterval = 10
    private let pushDebounce: TimeInterval = 2

    static let deviceID: String = {
        let key = "portal.syncDeviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    func setClient(_ client: GatewayClient) {
        if self.client !== client {
            self.client = client
            // New connection may be a different gateway — re-probe support.
            syncAvailable = nil
            lastPullAt = nil
        }
    }

    // MARK: - Pull

    /// Fetch the remote document if the throttle window has elapsed.
    /// Returns the remote doc for the caller to merge, or nil when skipped,
    /// unavailable, or empty.
    func pullIfDue(force: Bool = false) async -> Document? {
        guard syncAvailable != false, let client else { return nil }
        if !force, let last = lastPullAt, Date().timeIntervalSince(last) < minPullInterval {
            return nil
        }
        lastPullAt = Date()
        do {
            guard let result = try await client.getConfig(key: Self.configKey),
                  let json = result["value"]?.stringValue, !json.isEmpty,
                  let data = json.data(using: .utf8) else {
                syncAvailable = true
                return nil
            }
            let doc = try JSONDecoder.metaSync.decode(Document.self, from: data)
            syncAvailable = true
            return doc
        } catch {
            handleRPCError(error, op: "pull")
            return nil
        }
    }

    // MARK: - Push

    /// Debounced push — coalesces rapid mutations into one config.set.
    func schedulePush(_ makeDocument: @escaping @MainActor () -> Document) {
        guard syncAvailable != false else { return }
        pendingPush = true
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(2 * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pushTask = nil
            guard self.pendingPush else { return }
            self.pendingPush = false
            await self.push(makeDocument())
        }
    }

    func push(_ document: Document) async {
        guard syncAvailable != false, let client else { return }
        do {
            let data = try JSONEncoder.metaSync.encode(document)
            guard let json = String(data: data, encoding: .utf8) else { return }
            try await client.setConfig(key: Self.configKey, value: json)
            syncAvailable = true
        } catch {
            handleRPCError(error, op: "push")
            // Leave pendingPush semantics to the next mutation's debounce.
        }
    }

    // MARK: - Merge

    /// Merge remote entries into local: the newer entry per session wins.
    /// Returns (merged, localHadNewer) — push back when localHadNewer.
    static func merge(local: Document, remote: Document) -> (merged: Document, localHadNewer: Bool) {
        var merged = local
        var localHadNewer = false
        for (sessionID, remoteEntry) in remote.entries {
            if let localEntry = merged.entries[sessionID] {
                if remoteEntry.updatedAt > localEntry.updatedAt {
                    merged.entries[sessionID] = remoteEntry
                } else if localEntry != remoteEntry {
                    localHadNewer = true
                }
            } else {
                merged.entries[sessionID] = remoteEntry
            }
        }
        // Local-only entries the remote doesn't know about yet.
        if merged.entries.keys.contains(where: { remote.entries[$0] == nil }) {
            localHadNewer = true
        }
        return (merged, localHadNewer)
    }

    // MARK: - Errors

    private func handleRPCError(_ error: Error, op: String) {
        if let gwError = error as? GatewayError,
           case .rpcError(let rpc) = gwError,
           rpc.code == JSONRPCError.methodNotFound.code {
            log.info("Gateway lacks config.* support — session meta sync disabled")
            syncAvailable = false
            return
        }
        log.warning("Session meta \(op) failed: \(error.localizedDescription)")
    }
}

private extension JSONEncoder {
    static let metaSync: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

private extension JSONDecoder {
    static let metaSync: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
