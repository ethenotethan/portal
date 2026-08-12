import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "SRSStore")

/// Persists flashcard decks with SRS state to local disk.
/// Files live in Application Support/portal/srs-decks/<id>.json
/// This gives offline access to all decks and their review schedules.
@MainActor
final class SRSStore {
    static let shared = SRSStore()

    private let fileManager = FileManager.default
    private let srsDir: URL

    /// - Parameter directory: Where decks live. Defaults to Application
    ///   Support; `LearningStore`'s test initializer passes a temp dir so
    ///   tests never touch the user's real review history.
    internal init(directory: URL? = nil) {
        if let directory {
            srsDir = directory
        } else if let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first {
            srsDir = appSupport.appendingPathComponent("portal/srs-decks", isDirectory: true)
        } else {
            log.error("SRSStore: cannot locate Application Support directory")
            srsDir = URL(fileURLWithPath: "/tmp/portal/srs-decks")
        }
        try? fileManager.createDirectory(at: srsDir, withIntermediateDirectories: true)
    }

    // MARK: - Save

    /// Persist a single flashcard deck to disk. Runs on a background task
    /// to avoid blocking the main actor. Uses atomic write for safety.
    func saveDeck(_ deck: FlashcardDeck) {
        let file = srsDir.appendingPathComponent("\(deck.id).json")
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(deck)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("Failed to save deck \(deck.id): \(error)")
            }
        }
    }

    // MARK: - Load

    /// Load a single deck by ID. Returns nil if no local file exists.
    internal func loadDeck(id: String) -> FlashcardDeck? {
        let file = srsDir.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(FlashcardDeck.self, from: data)
        } catch {
            log.error("Failed to load deck \(id): \(error)")
            return nil
        }
    }

    // MARK: - List

    /// Return all decks persisted on disk by scanning the srs-decks directory.
    func allDecks() -> [FlashcardDeck] {
        guard let contents = try? fileManager.contentsOfDirectory(at: srsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let jsonFiles = contents.filter { $0.pathExtension == "json" }
        return jsonFiles.compactMap { file in
            do {
                let data = try Data(contentsOf: file)
                return try JSONDecoder().decode(FlashcardDeck.self, from: data)
            } catch {
                log.error("Failed to decode deck at \(file.lastPathComponent): \(error)")
                return nil
            }
        }
    }

    // MARK: - Delete

    /// Remove a deck's persisted file from disk.
    internal func deleteDeck(id: String) {
        let file = srsDir.appendingPathComponent("\(id).json")
        Task.detached(priority: .background) { [file] in
            try? FileManager.default.removeItem(at: file)
        }
    }
}
