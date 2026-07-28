import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CronRunHistoryStore")

struct CronRunRecord: Identifiable, Codable {
    let id: UUID
    let jobID: String
    let jobName: String
    let firedAt: Date
    var status: String
    var duration: TimeInterval?

    var durationLabel: String {
        guard let d = duration else { return "—" }
        if d < 60 { return String(format: "%.1fs", d) }
        if d < 3600 { return String(format: "%.1fm", d / 60) }
        return String(format: "%.1fh", d / 3600)
    }

    var isOk: Bool { status == "ok" }
}

@MainActor
final class CronRunHistoryStore: ObservableObject {
    static let shared = CronRunHistoryStore()

    @Published private(set) var records: [CronRunRecord] = []
    @Published var unreadCronRunCount: Int = 0

    private static let storageKey = "portal.cronRunHistory"
    private static let fileMigratedKey = "portal.cronRunHistory.fileMigrated"
    private let maxRecordsPerJob = 500

    private var previousLastRuns: [String: Date] = [:]
    private var saveTask: Task<Void, Never>?

    private let fileManager = FileManager.default
    private var storageDir: URL = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/portal")
        }
        return appSupport.appendingPathComponent("portal", isDirectory: true)
    }()
    private var storeFile: URL { storageDir.appendingPathComponent("cron-run-history.json") }

    private init() {
        load()
        rebuildPreviousState()
    }

    init(testing: Bool) {
        guard !testing else { return }
        load()
        rebuildPreviousState()
    }

    func markAllCronRunsRead() {
        unreadCronRunCount = 0
    }

    func detectNewRuns(from jobs: [CronJob]) {
        var didChange = false
        for job in jobs {
            guard let lastRun = job.lastRunAt else { continue }
            let prev = previousLastRuns[job.id]

            guard let prev else {
                previousLastRuns[job.id] = lastRun
                let alreadyRecorded = records.contains { $0.jobID == job.id && $0.firedAt == lastRun }
                if !alreadyRecorded {
                    records.append(CronRunRecord(
                        id: UUID(),
                        jobID: job.id,
                        jobName: job.name,
                        firedAt: lastRun,
                        status: job.lastStatus ?? "unknown",
                        duration: nil
                    ))
                    trim(jobID: job.id)
                    didChange = true
                }
                continue
            }

            if lastRun > prev {
                let alreadyRecorded = records.contains { $0.jobID == job.id && $0.firedAt == lastRun }
                if !alreadyRecorded {
                    let record = CronRunRecord(
                        id: UUID(),
                        jobID: job.id,
                        jobName: job.name,
                        firedAt: lastRun,
                        status: job.lastStatus ?? "unknown",
                        duration: nil
                    )
                    records.append(record)
                    trim(jobID: job.id)
                    didChange = true
                    NotificationService.shared.notifyCronComplete(
                        jobName: job.name,
                        status: job.lastStatus ?? "unknown",
                        jobID: job.id
                    )
                    unreadCronRunCount += 1
                }
                previousLastRuns[job.id] = lastRun
            }
        }
        if didChange { deferSave() }
    }

    func seedFromJobs(_ jobs: [CronJob]) {
        var didChange = false
        for job in jobs {
            guard let lastRun = job.lastRunAt else { continue }
            let alreadyRecorded = records.contains { $0.jobID == job.id && $0.firedAt == lastRun }
            if !alreadyRecorded {
                let record = CronRunRecord(
                    id: UUID(),
                    jobID: job.id,
                    jobName: job.name,
                    firedAt: lastRun,
                    status: job.lastStatus ?? "unknown",
                    duration: nil
                )
                records.append(record)
                trim(jobID: job.id)
                didChange = true
            }
            let prev = previousLastRuns[job.id]
            if let prev, lastRun > prev {
                previousLastRuns[job.id] = lastRun
            } else if prev == nil {
                previousLastRuns[job.id] = lastRun
            }
        }
        if didChange { deferSave() }
    }

    func records(for jobID: String) -> [CronRunRecord] {
        records.filter { $0.jobID == jobID }
            .sorted { $0.firedAt < $1.firedAt }
    }

    func allRecordsSorted() -> [CronRunRecord] {
        records.sorted { $0.firedAt < $1.firedAt }
    }

    func successRate(for jobID: String) -> Double {
        let jobRecords = records(for: jobID)
        guard !jobRecords.isEmpty else { return 0 }
        let okCount = jobRecords.filter { $0.isOk }.count
        return Double(okCount) / Double(jobRecords.count) * 100
    }

    func averageInterval(for jobID: String) -> TimeInterval? {
        let jobRecords = records(for: jobID)
        guard let first = jobRecords.first, let last = jobRecords.last else { return nil }
        let totalSpan = last.firedAt.timeIntervalSince(first.firedAt)
        return totalSpan / Double(jobRecords.count - 1)
    }

    private func trim(jobID: String) {
        let jobRecords = records.filter { $0.jobID == jobID }
        if jobRecords.count > maxRecordsPerJob {
            let toRemove = Set(jobRecords.dropLast(maxRecordsPerJob).map { $0.id })
            records.removeAll { toRemove.contains($0.id) }
        }
    }

    private func rebuildPreviousState() {
        for record in records {
            let prev = previousLastRuns[record.jobID]
            if let prev, record.firedAt > prev {
                previousLastRuns[record.jobID] = record.firedAt
            } else if prev == nil {
                previousLastRuns[record.jobID] = record.firedAt
            }
        }
    }

    private func deferSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
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
                log.error("cron-run-history save failed: \(error.localizedDescription)")
            }
        }
        UserDefaults.standard.set(true, forKey: Self.fileMigratedKey)
    }

    private func save() {
        performSave()
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
            records = try JSONDecoder().decode([CronRunRecord].self, from: data)
        } catch {
            log.error("cron-run-history load failed: \(error.localizedDescription)")
        }
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            records = try JSONDecoder().decode([CronRunRecord].self, from: data)
            performSave()
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } catch {
            log.error("cron-run-history migration decode failed: \(error.localizedDescription)")
        }
    }
}
