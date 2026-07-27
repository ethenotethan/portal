import Foundation
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "SessionRunEventStore")

struct SessionRunEvent: Identifiable, Codable, TokenAccountable {
    let id: UUID
    let sessionID: String
    let startedAt: Date
    var endedAt: Date?
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    var apiCalls: Int
    var costUSD: Double?
    var status: RunStatus

    enum RunStatus: String, Codable {
        case running
        case completed
        case failed
        case canceled
    }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    var durationLabel: String {
        guard let d = duration else { return "—" }
        if d < 60 { return String(format: "%.1fs", d) }
        if d < 3600 { return String(format: "%.1fm", d / 60) }
        return String(format: "%.1fh", d / 3600)
    }

    init(sessionID: String, startedAt: Date = Date()) {
        self.id = UUID()
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = nil
        self.inputTokens = nil
        self.outputTokens = nil
        self.totalTokens = nil
        self.apiCalls = 1
        self.costUSD = nil
        self.status = .running
    }
}

@MainActor
final class SessionRunHistoryStore: ObservableObject {
    static let shared = SessionRunHistoryStore()

    @Published private(set) var events: [SessionRunEvent] = []

    private static let storageKey = "hermes.sessionRunHistory"
    private static let fileMigratedKey = "hermes.sessionRunHistory.fileMigrated"
    private let maxEventsPerSession = 200
    private var saveTask: Task<Void, Never>?

    private let fileManager = FileManager.default
    private var storageDir: URL = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/hermes-native")
        }
        return appSupport.appendingPathComponent("hermes-native", isDirectory: true)
    }()
    private var storeFile: URL { storageDir.appendingPathComponent("session-run-history.json") }

    private init() {
        load()
    }

    func recordRunStart(sessionID: String) {
        let event = SessionRunEvent(sessionID: sessionID)
        events.append(event)
        trim(sessionID: sessionID)
        deferSave()
    }

    func recordRunEnd(
        sessionID: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = nil,
        apiCalls: Int = 1,
        costUSD: Double? = nil,
        status: SessionRunEvent.RunStatus = .completed
    ) {
        guard let idx = events.lastIndex(where: { $0.sessionID == sessionID && $0.status == .running }) else { return }
        events[idx].endedAt = Date()
        events[idx].inputTokens = inputTokens
        events[idx].outputTokens = outputTokens
        events[idx].totalTokens = totalTokens
        events[idx].apiCalls = apiCalls
        events[idx].costUSD = costUSD
        events[idx].status = status
        deferSave()
    }

    func events(for sessionID: String) -> [SessionRunEvent] {
        events.filter { $0.sessionID == sessionID }
            .sorted { $0.startedAt > $1.startedAt }
    }

    private func trim(sessionID: String) {
        let sessionEvents = events.filter { $0.sessionID == sessionID }
        if sessionEvents.count > maxEventsPerSession {
            let toRemove = Set(sessionEvents.dropLast(maxEventsPerSession).map { $0.id })
            events.removeAll { toRemove.contains($0.id) }
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
        let events = self.events
        let dir = storageDir
        let file = storeFile
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(events)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("session-run-event save failed: \(error.localizedDescription)")
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
            events = try JSONDecoder().decode([SessionRunEvent].self, from: data)
        } catch {
            log.error("session-run-event load failed: \(error.localizedDescription)")
        }
    }

    private func loadFromUserDefaults() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        do {
            events = try JSONDecoder().decode([SessionRunEvent].self, from: data)
            performSave()
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
        } catch {
            log.error("session-run-event migration decode failed: \(error.localizedDescription)")
        }
    }
}
