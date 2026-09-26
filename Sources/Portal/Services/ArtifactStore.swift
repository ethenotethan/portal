import Foundation
import Combine
import os

private let log = PortalLogger(category: "ArtifactStore")

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
        case succeeded(message: String?, sessionID: String?)
        case failed(reason: String)
        case conflict
        /// No handler ran. `reason` distinguishes the four very different ways
        /// that happens — a local bookkeeping miss, no gateway connection, a
        /// gateway with no artifact.action surface at all, or a successful round
        /// trip the harness answered `unsupported`. They used to collapse into
        /// one sentence about "the connected harness", which pointed at the
        /// server even when nothing had been sent to it.
        case unsupported(reason: String?)

        /// Map a ledger outcome string to a displayable state.
        /// Returns nil for non-terminal outcomes (needs_confirmation, running)
        /// which shouldn't be re-displayed after a restart.
        internal static func from(ledgerOutcome: String, reason: String?) -> IntentInvocationState? {
            switch ledgerOutcome {
            case "succeeded": return .succeeded(message: nil, sessionID: nil)
            case "failed":    return .failed(reason: reason ?? "Unknown error")
            case "conflict":  return .conflict
            case "unsupported": return .unsupported(reason: reason)
            default:          return nil
            }
        }
    }

    private weak var client: (any ArtifactGateway)?
    private var syncAvailable: Bool?
    private var pushTask: Task<Void, Never>?
    private let pushDebounce: TimeInterval = 2
    private let fileURL: URL

    /// Idempotency keys issued this session: (slotKey → UUID string).
    /// A retry for the same slot reuses the key — the server returns the
    /// original result rather than executing twice.
    private var idempotencyKeys: [String: String] = [:]

    /// The gateway that is currently "focused" in the UI. When non-nil,
    /// `sortedArtifacts` returns only artifacts owned by this gateway (plus
    /// legacy nil-gateway artifacts under the Hermes home gateway). New
    /// artifacts created while a gateway is focused are stamped with its id.
    @Published internal var focusedGatewayID: UUID?

    /// Artifacts sorted by recency for pickers, scoped to the focused
    /// gateway when one is set. Legacy artifacts (nil gatewayID) are
    /// treated as belonging to the Hermes home gateway and shown when no
    /// session-scoped gateway is focused.
    var sortedArtifacts: [LivingArtifact] {
        let all = artifacts.values.sorted { $0.updatedAt > $1.updatedAt }
        guard let focused = focusedGatewayID else { return all }
        // Session-scoped backend focused: show only its artifacts.
        // Nil-gateway (legacy/Hermes) artifacts are excluded when a
        // session-scoped gateway is active — they belong to Hermes.
        return all.filter { $0.gatewayID == focused }
    }

    private convenience init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "/tmp")
        let folder = dir.appendingPathComponent("portal", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.init(fileURL: folder.appendingPathComponent("artifacts.json"))
    }

    /// Isolated-store initializer for tests: back the store with a scratch
    /// `fileURL` (e.g. a temp dir) so a test drives its own `artifacts`,
    /// `intentStates`, and disk cache without touching the shared singleton or
    /// the production Application Support JSON.
    internal init(fileURL: URL) {
        self.fileURL = fileURL
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
            updatedBy: SessionMetaSyncService.deviceID,
            gatewayID: artifacts[id]?.gatewayID ?? focusedGatewayID
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

    // MARK: - Backend queries (the read side)

    /// One element's worth of query: which artifact, which declared query, and
    /// the page's exact `data-hermes-params` text — the key its result is
    /// written back under.
    internal struct QuerySlot: Hashable, Sendable {
        internal let artifactID: String
        internal let queryID: String
        internal let rawParams: String
        /// The page's `data-hermes-cursor` (empty = first page). Part of the key
        /// so each page is its own slot with its own result, and advancing the
        /// cursor never clobbers the page the element currently shows.
        internal let rawCursor: String
    }

    internal enum QueryState: Equatable {
        case loading
        /// `payload` is the JSON text the page reads out of its sink;
        /// `nextCursor` is the handler's paging token for the following page,
        /// nil when there are no more pages.
        case ok(payload: String, etag: String, nextCursor: String?)
        case failed(reason: String)
        case unsupported(reason: String)
    }

    /// Per-slot query results, projected onto the page by the HTML host.
    @Published internal private(set) var queryStates: [QuerySlot: QueryState] = [:]
    /// Gateway subscription handles for live slots, released with the view.
    private var querySubscriptions: [QuerySlot: String] = [:]
    private var queryTasks: [QuerySlot: Task<Void, Never>] = [:]

    /// Run (or re-run) a declared query for one page element.
    ///
    /// The artifact's manifest is checked here first — unknown query, bound key
    /// overridden, value out of range — so the page gets a readable reason
    /// without a round trip; the gateway checks again and is authoritative. A
    /// live query subscribes on first run, after which re-runs use the cheaper
    /// invoke and the gateway's `artifact.query.changed` drives them.
    internal func runQuery(artifactID: String, queryID: String, rawParams: String, rawCursor: String = "") {
        let slot = QuerySlot(artifactID: artifactID, queryID: queryID, rawParams: rawParams, rawCursor: rawCursor)
        queryTasks[slot]?.cancel()
        queryTasks[slot] = Task { [weak self] in
            await self?.performQuery(slot)
            self?.queryTasks[slot] = nil
        }
    }

    /// Record that a slot can't run at all on this client (no gateway surface),
    /// so the page hears `unsupported` instead of waiting.
    internal func markQueryUnsupported(
        artifactID: String, queryID: String, rawParams: String, rawCursor: String = "", reason: String
    ) {
        let slot = QuerySlot(artifactID: artifactID, queryID: queryID, rawParams: rawParams, rawCursor: rawCursor)
        queryStates[slot] = .unsupported(reason: reason)
    }

    /// Every slot for one artifact, for the host to project onto its page.
    internal func querySlots(artifactID: String) -> [(slot: QuerySlot, state: QueryState)] {
        queryStates.compactMap { $0.key.artifactID == artifactID ? ($0.key, $0.value) : nil }
    }

    /// The page went away: stop following its queries and forget their results.
    internal func releaseQueries(artifactID: String) {
        for (slot, task) in queryTasks where slot.artifactID == artifactID {
            task.cancel()
            queryTasks[slot] = nil
        }
        let handles = querySubscriptions.filter { $0.key.artifactID == artifactID }
        for (slot, handle) in handles {
            querySubscriptions[slot] = nil
            guard let client else { continue }
            Task {
                do {
                    try await client.artifactQueryUnsubscribe(handle: handle)
                } catch {
                    // Best effort: the gateway also drops a slot whose subscriber
                    // vanished, so a failed unsubscribe costs a few polls, not a leak.
                    log.info("artifact query unsubscribe failed for \(handle, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        queryStates = queryStates.filter { $0.key.artifactID != artifactID }
    }

    private func performQuery(_ slot: QuerySlot, retryingConflict: Bool = true) async {
        guard let artifact = artifacts[slot.artifactID] else {
            queryStates[slot] = .unsupported(reason: "This artifact isn't in the local store.")
            return
        }
        guard let client, syncAvailable != false else {
            queryStates[slot] = .unsupported(reason: "Not connected to a gateway.")
            return
        }
        guard let declaration = artifact.queries.first(where: { $0.id == slot.queryID }) else {
            queryStates[slot] = .unsupported(reason: "The artifact declares no query \(slot.queryID).")
            return
        }
        let params: [String: AnyCodable]
        do {
            let request = HTMLArtifactQueryRequest(queryID: slot.queryID, rawParams: slot.rawParams)
            params = try declaration.validate(try request.parameters())
        } catch {
            queryStates[slot] = .failed(reason: error.localizedDescription)
            return
        }
        // Keep the previous data on screen while it refreshes: a slot that
        // flashed empty on every poll would be worse than one that never moved.
        if case .ok = queryStates[slot] {} else { queryStates[slot] = .loading }

        let cursor = slot.rawCursor.isEmpty ? nil : slot.rawCursor
        do {
            let result: ArtifactQueryResult?
            // A cursored request is a point-in-time page read, so it always
            // invokes — subscribing per page would pin one subscription for
            // every page the reader scrolls through, and a "page N" slot has no
            // meaningful live identity. Only the uncursored base query (the
            // first page) follows the live-subscribe path.
            if declaration.isLive, cursor == nil, querySubscriptions[slot] == nil {
                result = try await client.artifactQuerySubscribe(
                    artifactID: slot.artifactID, artifactRev: artifact.rev,
                    queryID: slot.queryID, params: params
                )
            } else {
                result = try await client.artifactQueryInvoke(
                    artifactID: slot.artifactID, artifactRev: artifact.rev,
                    queryID: slot.queryID, params: params, cursor: cursor
                )
            }
            guard !Task.isCancelled else { return }
            guard let result else {
                queryStates[slot] = .unsupported(
                    reason: "This gateway has no artifact.query surface — it's too old for queries."
                )
                return
            }
            if let handle = result.subscription { querySubscriptions[slot] = handle }
            switch result.outcome {
            case .ok(let data, let etag, let nextCursor):
                queryStates[slot] = .ok(
                    payload: HTMLArtifactQueryBridge.payloadText(data), etag: etag, nextCursor: nextCursor)
            case .failed(let reason): queryStates[slot] = .failed(reason: reason)
            case .unsupported(let reason): queryStates[slot] = .unsupported(reason: reason)
            case .conflict:
                // The page rendered against a revision that has since moved on.
                // Pull the current artifact and go once more with its rev — one
                // retry, because a second conflict means the artifact is being
                // rewritten under us and the next artifact.changed will re-run.
                guard retryingConflict else {
                    queryStates[slot] = .failed(reason: "The artifact changed while the query ran.")
                    return
                }
                let fresh: LivingArtifact?
                do {
                    fresh = try await client.artifactGet(id: slot.artifactID)
                } catch {
                    queryStates[slot] = .failed(reason: error.localizedDescription)
                    return
                }
                guard let fresh else {
                    queryStates[slot] = .unsupported(reason: "The artifact is gone from the gateway.")
                    return
                }
                var stamped = fresh
                stamped.gatewayID = artifacts[slot.artifactID]?.gatewayID
                artifacts[slot.artifactID] = stamped
                await performQuery(slot, retryingConflict: false)
            }
        } catch {
            guard !Task.isCancelled else { return }
            queryStates[slot] = .failed(reason: error.localizedDescription)
        }
    }

    /// The gateway says a subscribed slot's data changed (or that the slot can
    /// no longer answer). Re-run every slot on that query.
    private func applyQueryChange(artifactID: String, queryID: String, status: String, reason: String) {
        let slots = queryStates.keys.filter { $0.artifactID == artifactID && $0.queryID == queryID }
        for slot in slots {
            if status == "unsupported" {
                querySubscriptions[slot] = nil
                queryStates[slot] = .unsupported(reason: reason.isEmpty ? "Query no longer available." : reason)
            } else {
                runQuery(artifactID: slot.artifactID, queryID: slot.queryID, rawParams: slot.rawParams)
            }
        }
    }

    /// An intent succeeded: the queries that declared it in `invalidated_by`
    /// are stale, so re-run them without waiting for a poll.
    private func invalidateQueries(artifactID: String, bindingID: String) {
        guard !bindingID.isEmpty, let artifact = artifacts[artifactID] else { return }
        let stale = Set(artifact.queries.filter { $0.invalidatedBy.contains(bindingID) }.map(\.id))
        guard !stale.isEmpty else { return }
        for slot in queryStates.keys where slot.artifactID == artifactID && stale.contains(slot.queryID) {
            runQuery(artifactID: slot.artifactID, queryID: slot.queryID, rawParams: slot.rawParams)
        }
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
            // Both of these are LOCAL failures — an artifact the store never
            // adopted, or no gateway connection at all — yet they surface the
            // same "not available on the connected harness" copy as a genuine
            // harness verdict. Say which it was, or the user is left auditing a
            // server that was never asked.
            let why = artifacts[artifactID] == nil
                ? "This artifact isn't in the local store, so nothing was sent."
                : "Not connected to a gateway — nothing was sent."
            log.notice("""
            artifact intent \(bindingID, privacy: .public) not dispatched: \
            \(self.artifacts[artifactID] == nil ? "artifact \(artifactID) is not in the store" : "no gateway client", privacy: .public)
            """)
            intentStates[slotKey(artifactID, bindingID, entryKey)] = .unsupported(reason: why)
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
                // nil means JSON-RPC -32601: this gateway has no
                // artifact.action.invoke method at all — every intent on every
                // artifact is dead, not just this binding.
                log.notice("""
                artifact intent \(bindingID, privacy: .public) not dispatched: gateway does not implement \
                artifact.action.invoke (method not found)
                """)
                intentStates[slot] = .unsupported(
                    reason: "This gateway has no artifact.action.invoke method — it's too old for intents."
                )
                return
            }
            applyInvokeResult(result, slot: slot, artifactID: artifactID, bindingID: bindingID)
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
                intentStates[slot] = .unsupported(
                    reason: "This gateway has no artifact.action.confirm method."
                )
                return
            }
            applyInvokeResult(result, slot: slot, artifactID: artifactID, bindingID: bindingID)
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
            let fetched: [[String: AnyCodable]]?
            do {
                fetched = try await client.artifactActionLog(artifactID: artifactID)
            } catch {
                log.debug("artifact action log fetch failed: \(error.localizedDescription)")
                return
            }
            guard let records = fetched else { return }
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
        _ result: ArtifactActionInvokeResult, slot: String, artifactID: String, bindingID: String = ""
    ) {
        switch result.outcome {
        case .needsConfirmation(let challenge, let prompt):
            intentStates[slot] = .needsConfirmation(challenge: challenge, prompt: prompt)
        case .succeeded(let message, let sessionID):
            intentStates[slot] = .succeeded(message: message, sessionID: sessionID)
            // Refresh the artifact so the UI reflects any server-side mutation
            // (tombstone, field update, etc.). Do not imply the refresh is part
            // of the external action result — they are separate outcomes.
            refreshArtifact(id: artifactID)
            // The write side telling the read side it is stale.
            invalidateQueries(artifactID: artifactID, bindingID: bindingID)
        case .failed(let reason):
            intentStates[slot] = .failed(reason: reason)
        case .conflict:
            intentStates[slot] = .conflict
            // Pull latest so the user sees the current state and can retry
            // with the updated revision.
            refreshArtifact(id: artifactID)
        case .unsupported:
            // The round trip SUCCEEDED and the gateway resolved the binding
            // against the pinned revision — it just has no handler registered
            // for the intent this artifact declares. Nothing client-side can
            // fix that, so name it as the gateway's verdict rather than letting
            // it read like the same local failure as the guards above.
            log.notice("""
            artifact intent \(bindingID, privacy: .public) on \(artifactID, privacy: .public) dispatched \
            successfully; gateway reported outcome=unsupported (no registered handler for this binding)
            """)
            intentStates[slot] = .unsupported(
                reason: "The gateway received this and has no handler registered for “\(bindingID)”."
            )
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

    /// Every live intent slot for one artifact, decoded back into its
    /// `(bindingID, entryKey)` components plus current state. Lets the HTML
    /// host reflect each control's status without knowing the composite-key
    /// format. `bindingID` never contains "/" (validated on the bridge), so the
    /// first separator after the known artifact prefix splits it from the entry
    /// key cleanly even when the entry key itself contains slashes.
    internal func intentSlots(
        artifactID: String
    ) -> [(bindingID: String, entryKey: String, state: IntentInvocationState)] {
        let prefix = "\(artifactID)/"
        return intentStates.compactMap { key, state in
            guard key.hasPrefix(prefix) else { return nil }
            let remainder = key.dropFirst(prefix.count)
            guard let slash = remainder.firstIndex(of: "/") else { return nil }
            let bindingID = String(remainder[remainder.startIndex..<slash])
            let entryKey = String(remainder[remainder.index(after: slash)...])
            return (bindingID, entryKey, state)
        }
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

    /// Inject a gateway for tests WITHOUT `setClient`'s side effects (no
    /// `pull()`, no event subscription), so intent state-machine tests stay
    /// deterministic. Marks sync available so `invokeIntent` proceeds.
    internal func injectClientForTesting(_ client: any ArtifactGateway) {
        self.client = client
        syncAvailable = true
    }

    /// Seed a fully-formed artifact (with a specific `rev`) directly, for
    /// tests that need to assert the pinned revision an intent invoke sends.
    /// Bypasses the upsert/merge path so `rev` is exactly as given.
    internal func seedArtifactForTesting(_ artifact: LivingArtifact) {
        artifacts[artifact.id] = artifact
    }

    /// Seed an intent slot's state directly, for tests that exercise slot
    /// decode / reflection without driving a full invoke round-trip.
    internal func seedIntentStateForTesting(
        artifactID: String, bindingID: String, entryKey: String,
        state: IntentInvocationState
    ) {
        intentStates[slotKey(artifactID, bindingID, entryKey)] = state
    }

    internal func setClient(_ client: any ArtifactGateway) {
        guard self.client !== client else { return }
        self.client = client
        syncAvailable = nil
        eventCancellable = client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event, _ in
                self?.handleGatewayEvent(event)
            }
        Task { await pull() }
    }

    /// The two gateway events the store acts on. Everything else is another
    /// store's concern.
    private func handleGatewayEvent(_ event: GatewayEvent) {
        switch event {
        case .artifactChanged(let id, let deleted):
            applyRemoteChange(id: id, deleted: deleted)
        case .artifactQueryChanged(let artifactID, let queryID, let status, let reason):
            applyQueryChange(artifactID: artifactID, queryID: queryID, status: status, reason: reason)
        default:
            break
        }
    }

    /// Deliver a gateway event without a live subscription, for tests: the
    /// Combine pipeline hops through the main run loop, which a test that
    /// yields on the main actor never spins.
    internal func applyGatewayEventForTesting(_ event: GatewayEvent) {
        handleGatewayEvent(event)
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
        let preservedGatewayID = artifacts[id]?.gatewayID ?? focusedGatewayID
        Task { [weak self] in
            guard let self else { return }
            guard let fresh = try? await client.artifactGet(id: id) else { return }
            // Ignore events for our own just-pushed writes only if stale:
            // rev is monotonic, so an older rev never overwrites a newer one.
            if let current = artifacts[id], current.rev >= fresh.rev, fresh.rev > 0 { return }
            // Preserve the local gateway-ownership stamp.
            var stamped = fresh
            stamped.gatewayID = preservedGatewayID
            artifacts[id] = stamped
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
                        // Preserve the local gateway-ownership stamp — it is a
                        // client-side annotation and is not round-tripped through
                        // the gateway wire format.
                        var stamped = full
                        stamped.gatewayID = local?.gatewayID ?? focusedGatewayID
                        artifacts[summary.id] = stamped
                        changed = true
                    }
                } else if var current = local {
                    // Rev unchanged, but the local copy came from the disk
                    // cache, which cannot persist actions or queries (their
                    // declaration types are not Codable). An app restart
                    // therefore wakes every artifact with empty manifests, and
                    // the rev guard would keep it that way forever. The list
                    // summary carries both manifests (the gateway strips only
                    // content), so re-adopt either missing one in place.
                    var restoredManifest = false
                    if current.topLevelActions.isEmpty, !summary.topLevelActions.isEmpty {
                        current.topLevelActions = summary.topLevelActions
                        restoredManifest = true
                    }
                    if current.queries.isEmpty, !summary.queries.isEmpty {
                        current.queries = summary.queries
                        restoredManifest = true
                    }
                    if restoredManifest { artifacts[summary.id] = current }
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
