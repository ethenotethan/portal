import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ArtifactStore")

/// Store for living artifacts: named models ANY writer maintains — chat
/// turns here, agent tool calls, cron jobs, workflows — synced through the
/// gateway's artifact.* surface. Three layers:
///
/// - In-memory published dictionary (views observe).
/// - Disk (Application Support JSON) — offline cache + pre-gateway fallback.
/// - Gateway (source of truth when available): full pull on connect,
///   revision-guarded (monotonic rev, stale never overwrites newer), and
///   artifact.changed events apply remote writes live — an agent updating
///   the BKK map appears in an open pane without polling.
@MainActor
final class ArtifactStore: ObservableObject {

    static let shared = ArtifactStore()

    @Published private(set) var artifacts: [String: LivingArtifact] = [:]

    private weak var client: GatewayClient?
    private var syncAvailable: Bool?
    private var pushTask: Task<Void, Never>?
    private let pushDebounce: TimeInterval = 2
    private let fileURL: URL

    /// Artifacts sorted by recency for pickers.
    var sortedArtifacts: [LivingArtifact] {
        artifacts.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/tmp")
        let folder = dir.appendingPathComponent("hermes-native", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent("artifacts.json")
        loadFromDisk()
    }

    // MARK: - Upsert (fence blocks with an id land here)

    /// Merge an incoming fence body into the named artifact. Returns the
    /// stored artifact after merge.
    @discardableResult
    func upsert(id: String, kind: String, title: String?, content: String) -> LivingArtifact {
        let merged: String
        if let existing = artifacts[id], existing.kind == kind {
            merged = ArtifactMerge.merge(kind: kind, existing: existing.content, incoming: content)
        } else {
            merged = content
        }
        var artifact = LivingArtifact(
            id: id,
            kind: kind,
            title: title ?? artifacts[id]?.title ?? "",
            content: merged,
            updatedAt: Date(),
            updatedBy: SessionMetaSyncService.deviceID
        )
        // Preserve a non-empty title over an incoming nil/empty one.
        if artifact.title.isEmpty, let existingTitle = artifacts[id]?.title {
            artifact.title = existingTitle
        }
        artifacts[id] = artifact
        persistToDisk()
        schedulePush(id: id)
        return artifact
    }

    func remove(id: String) {
        guard artifacts.removeValue(forKey: id) != nil else { return }
        persistToDisk()
        guard syncAvailable != false else { return }
        Task { [weak self] in try? await self?.client?.artifactDelete(id: id) }
    }

    // MARK: - Disk

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([String: LivingArtifact].self, from: data) else {
            return
        }
        artifacts = stored
    }

    private func persistToDisk() {
        let snapshot = artifacts
        let url = fileURL
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("artifact persist failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Gateway sync (artifact.* RPCs + artifact.changed events)

    func setClient(_ client: GatewayClient) {
        guard self.client !== client else { return }
        self.client = client
        syncAvailable = nil
        eventCancellable = client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event, _ in
                guard case .artifactChanged(let id, let deleted) = event else { return }
                self?.applyRemoteChange(id: id, deleted: deleted)
            }
        Task { await pull() }
    }

    private var eventCancellable: AnyCancellable?

    /// A gateway-side mutation happened (any writer: agent tool, cron,
    /// another device). Refetch that artifact so open panes update live.
    private func applyRemoteChange(id: String, deleted: Bool) {
        if deleted {
            if artifacts.removeValue(forKey: id) != nil { persistToDisk() }
            return
        }
        guard let client else { return }
        Task {
            guard let fresh = try? await client.artifactGet(id: id) else { return }
            // Ignore events for our own just-pushed writes only if stale:
            // rev is monotonic, so an older rev never overwrites a newer one.
            if let current = artifacts[id], current.rev >= fresh.rev, fresh.rev > 0 { return }
            artifacts[id] = fresh
            persistToDisk()
        }
    }

    /// Full resync: gateway list is the source of truth; local-only
    /// artifacts (created before the gateway had the surface, or offline)
    /// are pushed up. nil list = old gateway, stay local-only.
    func pull() async {
        guard let client, syncAvailable != false else { return }
        do {
            guard let remoteList = try await client.artifactList() else {
                syncAvailable = false
                log.info("artifact sync unavailable (gateway predates artifact.*)")
                return
            }
            syncAvailable = true
            var changed = false
            let remoteIDs = Set(remoteList.map(\.id))
            for summary in remoteList {
                let local = artifacts[summary.id]
                if local == nil || summary.rev > (local?.rev ?? 0) {
                    if let full = try? await client.artifactGet(id: summary.id) {
                        artifacts[summary.id] = full
                        changed = true
                    }
                }
            }
            // Push local-only artifacts up (offline creations).
            for (id, local) in artifacts where !remoteIDs.contains(id) && local.rev == 0 {
                if let stored = try? await client.artifactSet(
                    id: id, kind: local.kind, content: local.content, title: local.title
                ) {
                    artifacts[id] = stored
                    changed = true
                }
            }
            if changed { persistToDisk() }
        } catch {
            log.info("artifact pull failed: \(error.localizedDescription)")
        }
    }

    private func schedulePush(id: String) {
        guard syncAvailable != false else { return }
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.pushDebounce ?? 2))
            guard !Task.isCancelled else { return }
            await self?.push(id: id)
        }
    }

    /// Push one artifact's content. replace: the local content is already
    /// the merged state (upsert ran the client-side merge), so a server-side
    /// re-merge would double-apply on maps.
    private func push(id: String) async {
        guard let client, syncAvailable != false, let local = artifacts[id] else { return }
        do {
            if let stored = try await client.artifactSet(
                id: id, kind: local.kind, content: local.content,
                title: local.title.isEmpty ? nil : local.title, replace: true
            ) {
                artifacts[id] = stored
                persistToDisk()
            }
        } catch {
            log.info("artifact push failed: \(error.localizedDescription)")
        }
    }
}
