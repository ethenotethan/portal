import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "CurriculumStore")

/// Persists curricula to local disk, one JSON file per course in
/// Application Support/portal/curricula/<id>.json.
///
/// Two deliberate departures from its siblings `QuizStore` / `SRSStore`:
///  - Saving is an **upsert** on a stable id, because a curriculum is a living
///    record that accumulates progress rather than an immutable attempt log.
///  - It is **not a singleton**. The directory is an initializer parameter, so
///    a test can point one at a temp dir and callers name the dependency they
///    take. Owners hold one instance for their lifetime (`@State` in a view,
///    a stored property in a view model), so directory setup happens once.
@MainActor
internal final class CurriculumStore {
    private let fileManager = FileManager.default
    private let curriculaDir: URL

    /// - Parameter directory: Where courses live. Defaults to the app's
    ///   Application Support folder; pass a temp dir in tests.
    internal init(directory: URL? = nil) {
        curriculaDir = directory ?? Self.defaultDirectory()
        do {
            try fileManager.createDirectory(at: curriculaDir, withIntermediateDirectories: true)
        } catch {
            // Non-fatal: reads return empty and writes log their own failure,
            // so a bad directory degrades to "no saved courses" rather than
            // taking down the Learning page.
            log.error("Failed to create curricula directory at \(self.curriculaDir.path): \(error)")
        }
    }

    private static func defaultDirectory() -> URL {
        guard let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            log.error("Cannot locate Application Support directory — falling back to /tmp")
            return URL(fileURLWithPath: "/tmp/portal/curricula")
        }
        return appSupport.appendingPathComponent("portal/curricula", isDirectory: true)
    }

    // MARK: - Save

    /// Write a course to disk, replacing any prior version with the same id.
    /// Atomic, and off the main actor so progress updates mid-study don't stall
    /// the UI.
    internal func save(_ curriculum: Curriculum) {
        let file = curriculaDir.appendingPathComponent("\(curriculum.id).json")
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(curriculum)
                try data.write(to: file, options: .atomic)
            } catch {
                log.error("Failed to save curriculum \(curriculum.id): \(error)")
            }
        }
    }

    // MARK: - Load

    internal func load(id: String) -> Curriculum? {
        let file = curriculaDir.appendingPathComponent("\(id).json")
        guard fileManager.fileExists(atPath: file.path) else { return nil }
        do {
            return try JSONDecoder().decode(Curriculum.self, from: Data(contentsOf: file))
        } catch {
            log.error("Failed to load curriculum \(id): \(error)")
            return nil
        }
    }

    /// Every persisted course, newest first — the order the Learning page shows.
    internal func allCurricula() -> [Curriculum] {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(at: curriculaDir, includingPropertiesForKeys: nil)
        } catch {
            log.error("Failed to list curricula in \(self.curriculaDir.path): \(error)")
            return []
        }
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { file in
                do {
                    return try JSONDecoder().decode(Curriculum.self, from: Data(contentsOf: file))
                } catch {
                    log.error("Failed to decode curriculum at \(file.lastPathComponent): \(error)")
                    return nil
                }
            }
            .sorted { $0.created > $1.created }
    }

    // MARK: - Delete

    internal func delete(id: String) {
        let file = curriculaDir.appendingPathComponent("\(id).json")
        Task.detached(priority: .background) { [file] in
            do {
                try FileManager.default.removeItem(at: file)
            } catch {
                log.error("Failed to delete curriculum \(file.lastPathComponent): \(error)")
            }
        }
    }
}
