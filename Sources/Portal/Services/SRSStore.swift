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

    private init() {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log.error("SRSStore: cannot locate Application Support directory")
            srsDir = URL(fileURLWithPath: "/tmp/portal/srs-decks")
            try? fileManager.createDirectory(at: srsDir, withIntermediateDirectories: true)
            return
        }
        srsDir = appSupport.appendingPathComponent("portal/srs-decks", isDirectory: true)
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

    /// Persist multiple decks at once.
    func saveDecks(_ decks: [FlashcardDeck]) {
        for deck in decks {
            saveDeck(deck)
        }
    }

    // MARK: - Load

    /// Load a single deck by ID. Returns nil if no local file exists.
    func loadDeck(id: UUID) -> FlashcardDeck? {
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

    /// Return only decks that have cards due for review right now.
    func dueDecks() -> [FlashcardDeck] {
        allDecks().filter { $0.dueCount > 0 }
    }

    // MARK: - Delete

    /// Remove a deck's persisted file from disk.
    func deleteDeck(id: UUID) {
        let file = srsDir.appendingPathComponent("\(id).json")
        Task.detached(priority: .background) { [file] in
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Update

    /// Update the SRS state for a specific card within a deck and persist immediately.
    func updateCardState(deckID: UUID, cardID: UUID, newState: SRSState) {
        guard var deck = loadDeck(id: deckID) else {
            log.error("Cannot update card state: deck \(deckID) not found")
            return
        }
        deck.srsStates[cardID] = newState
        saveDeck(deck)
    }
}
