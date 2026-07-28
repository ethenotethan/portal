import Foundation
import os.log

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "WikiGraphCache")

/// On-disk cache of the last-known wiki graph, keyed by gateway identity and
/// wiki selection. It exists to kill the "click the wiki and wait for a blank
/// surface" latency: on a cold open the view model paints the cached graph
/// immediately, then refreshes it in the background from `wiki.scan`.
///
/// All disk access runs OFF the main actor. Reads hop to a detached task and
/// hand the decoded graph back; writes are fire-and-forget on a background
/// task. The view model only ever calls these async/void methods, so it never
/// performs synchronous file I/O itself (`no_sync_io_on_main`).
internal struct WikiGraphCache {

    /// Directory holding one JSON file per cache key. Overridable so tests
    /// drive a scratch dir instead of Application Support.
    private let directory: URL

    internal init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base
                .appendingPathComponent("portal", isDirectory: true)
                .appendingPathComponent("wiki-graph-cache", isDirectory: true)
        }
    }

    /// Return the cached graph for (identity, wiki), or nil when absent or
    /// unreadable. Runs off the main actor.
    internal func load(identity: String, wiki: String?) async -> WikiGraph? {
        let url = fileURL(identity: identity, wiki: wiki)
        return await Task.detached(priority: .userInitiated) {
            // A missing file is the ordinary cache-miss path (no prior scan for
            // this key) and stays quiet; a present-but-unreadable file is a real
            // fault worth a log. Either way we return nil — the cache is a pure
            // optimization and the live scan is the source of truth.
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(WikiGraph.self, from: data)
            } catch {
                log.error("wiki graph cache read failed: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    /// Persist the graph for (identity, wiki). Fire-and-forget on a background
    /// task; a write failure is logged, never surfaced (the cache is a pure
    /// optimization — the live scan is the source of truth).
    internal func store(_ graph: WikiGraph, identity: String, wiki: String?) {
        let url = fileURL(identity: identity, wiki: wiki)
        let dir = directory
        Task.detached(priority: .background) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(graph)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("wiki graph cache write failed: \(error.localizedDescription)")
            }
        }
    }

    private func fileURL(identity: String, wiki: String?) -> URL {
        directory.appendingPathComponent("\(Self.slug(identity: identity, wiki: wiki)).json")
    }

    /// Stable, filesystem-safe filename for a cache key. Uses a
    /// process-independent hash (djb2) because Swift's `Hashable` is salted
    /// per launch and so useless for on-disk keys that must survive restarts.
    internal static func slug(identity: String, wiki: String?) -> String {
        let key = "\(identity)|\(wiki ?? "_default")"
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(hash, radix: 16)
    }
}
