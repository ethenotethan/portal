import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "DelegationBatchHistoryStore")

/// Durable store of finished delegation batches, keyed by session — the batch
/// analogue of `CronRunHistoryStore`. `SpawnTreeStore` trees are in-memory and
/// gone when a session closes, so batches would otherwise be un-introspectable
/// after the fact. This persists a terminal batch's snapshot to app-support JSON
/// so reopening a past session still shows the batches it ran.
///
/// Deliberately the same shape as `CronRunHistoryStore`: an `ObservableObject`
/// with a `deferSave` debounce, per-key trim, and a one-time UserDefaults→file
/// migration. Unlike `CronRunHistoryStore` it is **not** a singleton — it's owned
/// by `SpawnTreeStore` (created once at app root) and reached through it, so it
/// stays injectable and testable.
@MainActor
internal final class DelegationBatchHistoryStore: ObservableObject {
    @Published internal private(set) var records: [DelegationBatchRecord] = []

    private static let storageKey = "portal.delegationBatchHistory"
    private static let fileMigratedKey = "portal.delegationBatchHistory.fileMigrated"
    /// Cap per session so a long-lived session that fans out constantly can't
    /// grow the file without bound.
    private let maxRecordsPerSession = 200

    /// Batch ids already persisted, so re-recording the same terminal batch (the
    /// store recomputes batches on every completion event) is a cheap no-op.
    private var recordedIDs: Set<String> = []
    private var saveTask: Task<Void, Never>?

    private let fileManager = FileManager.default
    private var storageDir: URL = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/portal")
        }
        return appSupport.appendingPathComponent("portal", isDirectory: true)
    }()
    private var storeFile: URL { storageDir.appendingPathComponent("delegation-batch-history.json") }

    internal init() {
        load()
        recordedIDs = Set(records.map(\.id))
    }

    /// Test seam — skip disk I/O so unit tests get an empty, isolated store.
    internal init(testing: Bool) {
        guard !testing else { return }
        load()
        recordedIDs = Set(records.map(\.id))
    }

    // MARK: - Recording

    /// Persist a terminal batch. Ignored if its id was already recorded, so the
    /// caller can fire this on every completion without deduping itself.
    internal func record(_ batch: DelegationBatch, sessionID: String) {
        guard !batch.isRunning, !recordedIDs.contains(batch.id) else { return }
        recordedIDs.insert(batch.id)
        records.append(DelegationBatchRecord(batch, sessionID: sessionID))
        trim(sessionID: sessionID)
        deferSave()
    }

    // MARK: - Queries

    /// A session's batches, oldest first.
    internal func records(for sessionID: String) -> [DelegationBatchRecord] {
        records.filter { $0.sessionID == sessionID }
            .sorted { $0.startedAt < $1.startedAt }
    }

    internal func allRecordsSorted() -> [DelegationBatchRecord] {
        records.sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: - Trim

    private func trim(sessionID: String) {
        let sessionRecords = records.filter { $0.sessionID == sessionID }
        guard sessionRecords.count > maxRecordsPerSession else { return }
        let sorted = sessionRecords.sorted { $0.startedAt < $1.startedAt }
        let toRemove = Set(sorted.dropLast(maxRecordsPerSession).map(\.id))
        records.removeAll { toRemove.contains($0.id) }
        recordedIDs.subtract(toRemove)
    }

    // MARK: - Persistence (mirrors CronRunHistoryStore)

    private func deferSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return // cancelled — nothing to persist
            }
            guard !Task.isCancelled else { return }
            performSave()
            saveTask = nil
        }
    }

    private func performSave() {
        let records = self.records
        let dir = storageDir
        let file = storeFile
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(records)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("delegation-batch-history save failed: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(true, forKey: Self.fileMigratedKey)
    }

    private func load() {
        if UserDefaults.standard.bool(forKey: Self.fileMigratedKey) {
            loadFromFile()
        } else {
            loadFromUserDefaults()
        }
    }

    private func loadFromFile() {
        guard fileManager.fileExists(atPath: storeFile.path) else { return }
        do {
            let data = try Data(contentsOf: storeFile)
            records = try JSONDecoder().decode([DelegationBatchRecord].self, from: data)
        } catch {
            log.error("delegation-batch-history load failed: \(error.localizedDescription)")
        }
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            records = try JSONDecoder().decode([DelegationBatchRecord].self, from: data)
            performSave()
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } catch {
            log.error("delegation-batch-history migration decode failed: \(error.localizedDescription)")
        }
    }
}
