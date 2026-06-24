import Foundation
import os

/// Downloads digest videos in full (single non-ranged GET) and caches them on
/// disk so AVPlayer can play a local file.
///
/// Why this exists: the gateway's `/v1/media` route has an off-by-one in its
/// HTTP Range handling — every ranged request returns one byte too few, and
/// `bytes=0-0` returns 416. AVPlayer streams via range requests, so it fails
/// with CoreMedia error -12939 ("Operation Stopped"). A plain GET with no
/// Range header returns the complete, valid file (verified: 200, full
/// Content-Length, intact moov atom), so we fetch the whole thing once and
/// hand AVPlayer a `file://` URL, which needs no ranges.
///
/// Remove this shim once the server serves inclusive ranges (RFC 7233).
@MainActor
final class VideoCache {
    static let shared = VideoCache()

    private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "video")
    private let session: URLSession
    /// In-flight + completed downloads keyed by remote URL, so repeated taps on
    /// the same card reuse one download instead of stacking concurrent fetches.
    private var tasks: [URL: Task<URL, Error>] = [:]

    private init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    /// Directory holding cached video files. Created lazily.
    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("hermes-videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stable on-disk path for a remote URL (hashed so odd characters/length
    /// can't break the filename), preserving the original extension.
    private func localURL(for remote: URL) -> URL {
        let ext = remote.pathExtension.isEmpty ? "mp4" : remote.pathExtension
        let key = String(UInt64(bitPattern: Int64(remote.absoluteString.hashValue)))
        return cacheDirectory.appendingPathComponent("\(key).\(ext)")
    }

    /// Returns a local file URL for `remote`, downloading the full file first if
    /// it isn't already cached. Coalesces concurrent requests for the same URL.
    func localFile(for remote: URL) async throws -> URL {
        let destination = localURL(for: remote)
        if FileManager.default.fileExists(atPath: destination.path) {
            log.debug("video cache hit: \(destination.lastPathComponent, privacy: .public)")
            return destination
        }
        if let existing = tasks[remote] {
            return try await existing.value
        }

        let task = Task<URL, Error> { [session, log] in
            // A plain GET — no Range header — so the server returns 200 with the
            // whole file, sidestepping the broken partial-content path.
            log.debug("downloading video: \(remote.absoluteString, privacy: .public)")
            let (tmp, response) = try await session.download(from: remote)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                throw URLError(.badServerResponse,
                               userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) downloading video"])
            }
            // Move into place atomically; replace any partial leftover.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
            log.debug("video downloaded: \(destination.lastPathComponent, privacy: .public)")
            return destination
        }
        tasks[remote] = task
        defer { tasks[remote] = nil }
        return try await task.value
    }
}
