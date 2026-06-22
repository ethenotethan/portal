import Foundation
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "QuizStore")

/// Persists completed quiz sessions to local disk for the Learning Dashboard.
/// Files live in Application Support/hermes-native/quizzes/<id>.json
@MainActor
final class QuizStore {
    static let shared = QuizStore()

    private let fileManager = FileManager.default
    private let quizzesDir: URL

    private init() {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log.error("QuizStore: cannot locate Application Support directory")
            quizzesDir = URL(fileURLWithPath: "/tmp/hermes-native/quizzes")
            try? fileManager.createDirectory(at: quizzesDir, withIntermediateDirectories: true)
            return
        }
        quizzesDir = appSupport.appendingPathComponent("hermes-native/quizzes", isDirectory: true)
        try? fileManager.createDirectory(at: quizzesDir, withIntermediateDirectories: true)
    }

    // MARK: - Save

    /// Persist a completed quiz session to disk.
    func saveQuiz(_ session: PersistedQuizSession) {
        let file = quizzesDir.appendingPathComponent("\(session.id).json")
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(session)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("Failed to save quiz \(session.id): \(error)")
            }
        }
    }

    // MARK: - Load

    /// Load a single quiz session by ID.
    func loadQuiz(id: UUID) -> PersistedQuizSession? {
        let file = quizzesDir.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        do {
            let data = try Data(contentsOf: file)
            return try JSONDecoder().decode(PersistedQuizSession.self, from: data)
        } catch {
            log.error("Failed to load quiz \(id): \(error)")
            return nil
        }
    }

    // MARK: - List

    /// Return all quiz sessions sorted by completion date (newest first).
    func allQuizzes() -> [PersistedQuizSession] {
        guard let contents = try? fileManager.contentsOfDirectory(at: quizzesDir, includingPropertiesForKeys: nil) else {
            return []
        }
        let jsonFiles = contents.filter { $0.pathExtension == "json" }
        return jsonFiles.compactMap { file in
            do {
                let data = try Data(contentsOf: file)
                return try JSONDecoder().decode(PersistedQuizSession.self, from: data)
            } catch {
                log.error("Failed to decode quiz at \(file.lastPathComponent): \(error)")
                return nil
            }
        }.sorted { $0.completedAt > $1.completedAt }
    }

    // MARK: - Delete

    /// Remove a quiz's persisted file from disk.
    func deleteQuiz(id: UUID) {
        let file = quizzesDir.appendingPathComponent("\(id).json")
        Task.detached(priority: .background) { [file] in
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Remove all quizzes from disk.
    func deleteAllQuizzes() {
        let quizzes = allQuizzes()
        for quiz in quizzes {
            deleteQuiz(id: quiz.id)
        }
    }
}