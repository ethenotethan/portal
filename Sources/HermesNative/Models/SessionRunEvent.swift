import Foundation

struct SessionRunEvent: Identifiable, Codable {
    let id: UUID
    let sessionID: String
    let startedAt: Date
    var endedAt: Date?
    var inputTokens: Int
    var outputTokens: Int
    var totalTokens: Int
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
        self.inputTokens = 0
        self.outputTokens = 0
        self.totalTokens = 0
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
    private let maxEventsPerSession = 200
    private var saveTask: Task<Void, Never>?

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
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        totalTokens: Int = 0,
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
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(events) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([SessionRunEvent].self, from: data) {
            events = decoded
        }
    }
}
