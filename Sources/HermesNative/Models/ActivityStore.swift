import Foundation
import os.log

private let storeLog = Logger(subsystem: "hermes", category: "ActivityStore")

@MainActor
final class ActivityStore {
    static let shared = ActivityStore()

    private let defaults = UserDefaults.standard
    private let maxItems = 500
    private let saveKey = "hermes.activityItems"
    private static let fileMigratedKey = "hermes.activityItems.fileMigrated"
    private var dirty = false
    private var saveTask: Task<Void, Never>?

    private let fileManager = FileManager.default
    private var storageDir: URL = {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return URL(fileURLWithPath: "/tmp/hermes-native")
        }
        return appSupport.appendingPathComponent("hermes-native", isDirectory: true)
    }()
    private var storeFile: URL { storageDir.appendingPathComponent("activity-items.json") }

    private(set) var items: [ActivityItem] = [] {
        didSet { scheduleSave() }
    }

    private init() {
        load()
    }

    func upsert(_ item: ActivityItem) {
        if item.isDismissed {
            items.removeAll { $0.id == item.id }
        } else if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx] = item
        } else {
            items.insert(item, at: 0)
        }
        items.sort { $0.createdAt > $1.createdAt }
        trim()
    }

    func markRead(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isRead = true
    }

    func dismiss(id: String) {
        items.removeAll { $0.id == id }
    }

    func markAllRead() {
        for i in items.indices where !items[i].isRead {
            items[i].isRead = true
        }
    }

    func clearAll() {
        items.removeAll()
    }

    var unreadCount: Int {
        items.filter { !$0.isRead }.count
    }

    private func trim() {
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
    }

    private func scheduleSave() {
        guard !dirty else { return }
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            save()
            dirty = false
        }
    }

    func saveNow() {
        save()
    }

    private func save() {
        let items = self.items
        let dir = storageDir
        let file = storeFile
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(items)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                storeLog.error("save failed: \(error.localizedDescription)")
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
            items = try JSONDecoder().decode([ActivityItem].self, from: data)
        } catch {
            storeLog.error("loadFromFile failed: \(error.localizedDescription)")
            items = []
        }
    }

    private func loadFromUserDefaults() {
        guard let data = defaults.data(forKey: saveKey) else { return }
        do {
            items = try JSONDecoder().decode([ActivityItem].self, from: data)
            save()
            UserDefaults.standard.removeObject(forKey: saveKey)
        } catch {
            storeLog.error("load failed: \(error.localizedDescription)")
            items = []
        }
    }
}
