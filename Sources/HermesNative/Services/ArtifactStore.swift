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

    // MARK: - Intent invocation state

    /// One entry per in-flight or recently-completed intent invocation.
    /// Keyed by "artifactID/bindingID/entryKey" so each (button × row) slot
    /// has independent state without blocking sibling rows.
    @Published internal private(set) var intentStates: [String: IntentInvocationState] = [:]

    internal enum IntentInvocationState: Equatable {
        case pending
        case needsConfirmation(challenge: String, prompt: String)
        case succeeded(message: String?)
        case failed(reason: String)
        case conflict
        case unsupported

        /// Map a ledger outcome string to a displayable state.
        /// Returns nil for non-terminal outcomes (needs_confirmation, running)
        /// which shouldn't be re-displayed after a restart.
        static func from(ledgerOutcome: String, reason: String?) -> IntentInvocationState? {
            switch ledgerOutcome {
            case "succeeded": return .succeeded(message: nil)
            case "failed":    return .failed(reason: reason ?? "Unknown error")
            case "conflict":  return .conflict
            case "unsupported": return .unsupported
            default:          return nil
            }
        }
    }

    private weak var client: GatewayClient?
    private var syncAvailable: Bool?
    private var pushTask: Task<Void, Never>?
    private let pushDebounce: TimeInterval = 2
    private let fileURL: URL

    /// Idempotency keys issued this session: (slotKey → UUID string).
    /// A retry for the same slot reuses the key — the server returns the
    /// original result rather than executing twice.
    private var idempotencyKeys: [String: String] = [:]

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

    // MARK: - User actions (declared per-artifact, executed on entries)

    /// Apply a declared action to one entry of a dataset/map artifact:
    /// choice/toggle set a field, delete tombstones. Content mutates through
    /// the same upsert→push path agent writes use, so the user's triage is
    /// visible to agents on their next get and lands in revision history
    /// attributed to this device.
    func applyAction(
        artifactID: String, action: ArtifactAction, entryKey: String, value: String? = nil
    ) {
        guard let artifact = artifacts[artifactID] else { return }
        let mutated: String?
        switch action.kind {
        case .delete:
            mutated = ArtifactActionEngine.markDeleted(
                in: artifact.content, kind: artifact.kind, entryKey: entryKey
            )
        case .toggle:
            let current = currentFieldValue(in: artifact, entryKey: entryKey, field: action.field)
            mutated = ArtifactActionEngine.setField(
                in: artifact.content, kind: artifact.kind, entryKey: entryKey,
                field: action.field, value: !ArtifactAction.isTruthy(current)
            )
        case .choice:
            guard let value, action.options.contains(value) else { return }
            mutated = ArtifactActionEngine.setField(
                in: artifact.content, kind: artifact.kind, entryKey: entryKey,
                field: action.field, value: value
            )
        case .intent:
            // Backend intents are dispatched through invokeIntent(), not here.
            return
        }
        guard let content = mutated else { return }
        var updated = artifact
        updated.content = content
        updated.updatedAt = Date()
        updated.updatedBy = "user:\(SessionMetaSyncService.deviceID)"
        artifacts[artifactID] = updated
        persistToDisk()
        schedulePush(id: artifactID)
    }

    // MARK: - Backend intent invocation

    /// Invoke a backend intent declared by the artifact. The gateway resolves
    /// the binding from the artifact's pinned revision and validates its
    /// registered handler — this method never supplies executable content.
    ///
    /// The slot (artifactID/bindingID/entryKey) carries independent state so
    /// each row's button gives its own feedback without blocking siblings.
    /// Idempotency: the same slot reuses its UUID so a retry or double-click
    /// does not execute the handler twice.
    internal func invokeIntent(
        artifactID: String,
        bindingID: String,
        entryKey: String
    ) async {
        guard let artifact = artifacts[artifactID],
              let client else {
            intentStates[slotKey(artifactID, bindingID, entryKey)] = .unsupported
            return
        }
        let slot = slotKey(artifactID, bindingID, entryKey)
        // Reuse the idempotency key for this slot so retries are no-ops.
        let ikey: String
        if let existing = idempotencyKeys[slot] {
            ikey = existing
        } else {
            ikey = UUID().uuidString
            idempotencyKeys[slot] = ikey
        }
        intentStates[slot] = .pending
        do {
            guard let result = try await client.artifactActionInvoke(
                artifactID: artifactID,
                artifactRev: artifact.rev,
                bindingID: bindingID,
                entityRef: entryKey,
                idempotencyKey: ikey
            ) else {
                intentStates[slot] = .unsupported
                return
            }
            applyInvokeResult(result, slot: slot, artifactID: artifactID)
        } catch {
            intentStates[slot] = .failed(reason: error.localizedDescription)
        }
    }

    /// Confirm a pending destructive intent after the user approves the
    /// native confirmation dialog. `challenge` is the short-lived token the
    /// gateway returned in the needs_confirmation response — it is bound to
    /// actor, revision, binding, and expiry server-side so the artifact
    /// cannot weaken confirmation policy.
    internal func confirmIntent(
        artifactID: String,
        bindingID: String,
        entryKey: String,
        challenge: String
    ) async {
        guard let client else { return }
        let slot = slotKey(artifactID, bindingID, entryKey)
        intentStates[slot] = .pending
        do {
            guard let result = try await client.artifactActionConfirm(
                artifactID: artifactID,
                challenge: challenge
            ) else {
                intentStates[slot] = .unsupported
                return
            }
            applyInvokeResult(result, slot: slot, artifactID: artifactID)
        } catch {
            intentStates[slot] = .failed(reason: error.localizedDescription)
        }
    }

    /// Re-seed badge state from the gateway's invocation ledger.
    ///
    /// Called when the artifact pane opens after an app restart. The ledger
    /// records every terminal outcome durably (§2), so we can restore ✓/⚠
    /// badges that were live when the app quit. Only the most-recent record
    /// per (bindingID × entityRef) slot is used — newer outcomes supersede.
    ///
    /// Live states from the current session (.pending, .needsConfirmation)
    /// are never overwritten — a slot with an in-flight request takes
    /// precedence over any historical record.
    internal func rehydrateBadges(for artifactID: String) {
        guard let client else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let records = try? await client.artifactActionLog(artifactID: artifactID) else { return }
            // Records arrive newest-first. Walk them once, seeding only the
            // first (newest) terminal outcome seen for each slot.
            var seenSlots = Set<String>()
            for record in records {
                guard
                    let bindingID = record["binding_id"]?.stringValue,
                    let entityRef = record["entity_ref"]?.stringValue,
                    let outcomeStr = record["outcome"]?.stringValue
                else { continue }
                let slot = slotKey(artifactID, bindingID, entityRef)
                guard !seenSlots.contains(slot) else { continue }
                seenSlots.insert(slot)
                // Don't overwrite a live in-session state.
                switch intentStates[slot] {
                case .pending, .needsConfirmation: continue
                default: break
                }
                let state = IntentInvocationState.from(ledgerOutcome: outcomeStr,
                                                       reason: record["reason"]?.stringValue)
                guard let state else { continue }
                intentStates[slot] = state
            }
        }
    }

    /// Clear the invocation state for a slot so the button resets to idle.
    internal func clearIntentState(artifactID: String, bindingID: String, entryKey: String) {
        let slot = slotKey(artifactID, bindingID, entryKey)
        intentStates.removeValue(forKey: slot)
        idempotencyKeys.removeValue(forKey: slot)
    }

    private func applyInvokeResult(
        _ result: ArtifactActionInvokeResult, slot: String, artifactID: String
    ) {
        switch result.outcome {
        case .needsConfirmation(let challenge, let prompt):
            intentStates[slot] = .needsConfirmation(challenge: challenge, prompt: prompt)
        case .succeeded(let message):
            intentStates[slot] = .succeeded(message: message)
            // Refresh the artifact so the UI reflects any server-side mutation
            // (tombstone, field update, etc.). Do not imply the refresh is part
            // of the external action result — they are separate outcomes.
            refreshArtifact(id: artifactID)
        case .failed(let reason):
            intentStates[slot] = .failed(reason: reason)
        case .conflict:
            intentStates[slot] = .conflict
            // Pull latest so the user sees the current state and can retry
            // with the updated revision.
            refreshArtifact(id: artifactID)
        case .unsupported:
            intentStates[slot] = .unsupported
        }
    }

    private func refreshArtifact(id: String) {
        guard let client else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let fresh = try await client.artifactGet(id: id) else { return }
                if let current = self.artifacts[id], current.rev >= fresh.rev, fresh.rev > 0 { return }
                self.artifacts[id] = fresh
                self.persistToDisk()
            } catch {
                log.debug("refreshArtifact(\(id)) failed: \(error.localizedDescription)")
            }
        }
    }

    private func slotKey(_ artifactID: String, _ bindingID: String, _ entryKey: String) -> String {
        "\(artifactID)/\(bindingID)/\(entryKey)"
    }

    /// Expose slot key construction to views so they can look up state.
    internal func intentSlotKey(artifactID: String, bindingID: String, entryKey: String) -> String {
        slotKey(artifactID, bindingID, entryKey)
    }

    /// Set the artifact's maintainers (the crons that keep it current),
    /// rewriting the content's top-level `maintainers` array. Goes through the
    /// same user-attributed upsert→push path as declared actions, so the link
    /// syncs to the gateway and lands in revision history. No-op when the
    /// content isn't JSON (markdown docs can't declare maintainers).
    func setMaintainers(artifactID: String, refs: [MaintainerRef]) {
        guard let artifact = artifacts[artifactID],
              let content = MaintainerRef.write(refs, into: artifact.content) else { return }
        guard content != artifact.content else { return }
        var updated = artifact
        updated.content = content
        updated.updatedAt = Date()
        updated.updatedBy = "user:\(SessionMetaSyncService.deviceID)"
        artifacts[artifactID] = updated
        persistToDisk()
        schedulePush(id: artifactID)
    }

    private func currentFieldValue(in artifact: LivingArtifact, entryKey: String, field: String) -> String? {
        guard let data = artifact.content.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Ensemble model: entryKey is a "set/keyValue" ref.
        if artifact.kind == "model" {
            guard let ref = ModelSpec.EntityRef(entryKey),
                  let setObj = (obj["entities"] as? [String: [String: Any]])?[ref.set],
                  let items = setObj["items"] as? [[String: Any]] else { return nil }
            let keyField = (setObj["key"] as? String) ?? "id"
            let entry = items.first {
                String(describing: $0[keyField] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == ref.key
            }
            return entry?[field].map { String(describing: $0) }
        }
        let listField = artifact.kind == "map" ? "markers" : "rows"
        let keyField = artifact.kind == "map" ? "label" : ((obj["key"] as? String) ?? "id")
        let target = entryKey.trimmingCharacters(in: .whitespaces).lowercased()
        let entry = (obj[listField] as? [[String: Any]])?.first {
            String(describing: $0[keyField] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == target
        }
        return entry?[field].map { String(describing: $0) }
    }

    func remove(id: String) {
        guard artifacts.removeValue(forKey: id) != nil else { return }
        persistToDisk()
        guard !Self.isTestProcess, syncAvailable != false else { return }
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

    /// True when running inside a test process. Tests exercise the shared
    /// store (singleton), and without this guard a test upsert schedules a
    /// REAL gateway push when a client happens to be wired — unit tests
    /// leaked test-artifact-* entries into the production store.
    private static let isTestProcess = ProcessInfo.isTestProcess

    private func schedulePush(id: String) {
        guard !Self.isTestProcess else { return }
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
