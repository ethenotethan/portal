import Foundation

/// Gigabytes, the way a download prompt should say them.
internal enum ByteCountLabel {
    /// `3.0 GB`. Decimal gigabytes on purpose: these numbers are compared against
    /// what Hugging Face shows on the model page, not against a disk utility.
    internal static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

/// Whether one model's weights are already on this machine.
internal struct LocalModelPresence: Sendable, Equatable {
    /// A usable copy is on disk — asking for it costs a load, not a download.
    internal let isDownloaded: Bool
    /// What it occupies, including a half-finished download's bytes. Shown so the
    /// user can see where 17 GB of disk went.
    internal let bytesOnDisk: Int64

    internal static let absent = LocalModelPresence(isDownloaded: false, bytesOnDisk: 0)
}

/// What the app knows about the local model situation: which of the lineup is
/// already downloaded, and how much disk that is.
///
/// A plain immutable value, so views read it without touching the filesystem and
/// tests build one by hand. `LocalModelCacheScanner` is what produces it.
internal struct LocalModelInventory: Sendable, Equatable {
    private let presence: [LocalChatModel: LocalModelPresence]

    internal init(presence: [LocalChatModel: LocalModelPresence] = [:]) {
        self.presence = presence
    }

    /// Nothing known yet — what the app starts with before the first scan, and
    /// what a machine with no cache directory reports.
    internal static let unknown = LocalModelInventory()

    internal func presence(of model: LocalChatModel) -> LocalModelPresence {
        presence[model] ?? .absent
    }

    internal func isDownloaded(_ model: LocalChatModel) -> Bool {
        presence(of: model).isDownloaded
    }

    /// Downloaded models in lineup order (smallest first), so the Settings line
    /// reads the same way every time rather than in dictionary order.
    internal var downloadedModels: [LocalChatModel] {
        LocalChatModel.allCases.filter(isDownloaded)
    }

    internal var downloadedSet: Set<LocalChatModel> { Set(downloadedModels) }

    /// Disk used by the lineup — including partial downloads, which is precisely
    /// the space the user wants to know about.
    internal var totalBytesOnDisk: Int64 {
        presence.values.reduce(0) { $0 + $1.bytesOnDisk }
    }

    /// `Gemma 3 1B, Qwen3 4B (3.0 GB)`, or nil when nothing is downloaded yet —
    /// there is no point printing an empty list.
    internal var summary: String? {
        let downloaded = downloadedModels
        guard !downloaded.isEmpty else { return nil }
        let names = downloaded.map(\.label).joined(separator: ", ")
        return "\(names) (\(ByteCountLabel.gigabytes(totalBytesOnDisk)))"
    }

    /// How Settings should describe asking for this model right now.
    internal func status(of model: LocalChatModel) -> String {
        isDownloaded(model) ? "downloaded" : "\(model.downloadSize) to fetch"
    }
}

/// Reads the Hugging Face hub cache to find out which models are already here.
///
/// The cache is shared with every other Hugging Face client on the machine
/// (including Python's `huggingface_hub` and this app's own skill summarizer), so
/// a model can be present because something else fetched it — which is the whole
/// reason to look rather than to track downloads ourselves.
///
/// The layout it reads is the standard one:
/// ```
/// <root>/models--mlx-community--Qwen3-4B-4bit/
///   blobs/<etag>              ← the real bytes
///   blobs/<etag>.incomplete   ← a download in progress
///   snapshots/<revision>/config.json → symlink into blobs/
/// ```
internal struct LocalModelCacheScanner: Sendable {
    /// Hub cache root, or nil when there isn't one to read (no cache directory
    /// yet, nothing downloaded).
    internal let root: URL?

    /// The scanner for this machine.
    internal static func current() -> LocalModelCacheScanner {
        LocalModelCacheScanner(root: defaultRoot())
    }

    /// Where `HubClient` puts weights, resolved the same way it does — the point
    /// is to read the *same* directory the downloader writes, so the priority
    /// order (and the sandbox fallback) has to match `swift-huggingface`'s
    /// `CacheLocationProvider`, which in turn matches Python's `huggingface_hub`.
    internal static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        cachesDirectory: URL = .cachesDirectory
    ) -> URL {
        if let hubCache = environment["HF_HUB_CACHE"] {
            return URL(fileURLWithPath: NSString(string: hubCache).expandingTildeInPath)
        }
        if let home = environment["HF_HOME"] {
            return URL(fileURLWithPath: NSString(string: home).expandingTildeInPath)
                .appendingPathComponent("hub")
        }
        #if os(macOS)
        // A sandboxed app can't see ~/.cache, so the hub falls back to the
        // container's caches directory and so must this.
        if environment["APP_SANDBOX_CONTAINER_ID"] == nil {
            return homeDirectory
                .appendingPathComponent(".cache")
                .appendingPathComponent("huggingface")
                .appendingPathComponent("hub")
        }
        #endif
        return cachesDirectory
            .appendingPathComponent("huggingface")
            .appendingPathComponent("hub")
    }

    /// `mlx-community/Qwen3-4B-4bit` → `models--mlx-community--Qwen3-4B-4bit`.
    internal static func directoryName(forRepository repository: String) -> String {
        "models--" + repository.replacingOccurrences(of: "/", with: "--")
    }

    /// Look at every model in the lineup. Cheap — a handful of directory
    /// listings — but it is filesystem work, so callers keep it off the main
    /// thread except on the first-run path that has to answer synchronously.
    internal func scan(_ models: [LocalChatModel] = LocalChatModel.allCases) -> LocalModelInventory {
        guard let root else { return .unknown }
        var presence: [LocalChatModel: LocalModelPresence] = [:]
        for model in models {
            let repository = root.appendingPathComponent(
                Self.directoryName(forRepository: model.repositoryID)
            )
            presence[model] = self.presence(of: model, in: repository)
        }
        return LocalModelInventory(presence: presence)
    }

    private func presence(of model: LocalChatModel, in repository: URL) -> LocalModelPresence {
        let blobs = blobBytes(in: repository.appendingPathComponent("blobs"))
        guard blobs.total > 0 else { return .absent }
        // Three conditions, because "the directory exists" is not the question:
        // an interrupted download leaves a repo directory, some blobs, and a
        // snapshot whose symlinks dangle. So require a resolvable config.json (the
        // symlinks point at real bytes), no in-progress blob, and roughly the
        // expected weight size (a sharded model can have four of five shards and
        // satisfy the first two).
        let complete = hasResolvableConfig(in: repository.appendingPathComponent("snapshots"))
            && !blobs.hasIncomplete
            && blobs.finished >= Int64(Double(model.downloadBytes) * 0.8)
        return LocalModelPresence(isDownloaded: complete, bytesOnDisk: blobs.total)
    }

    /// Bytes this repo occupies, and whether a download is mid-flight. Partial
    /// blobs count towards the total — they are on the disk either way, and the
    /// space is what the user is being told about — but they also mark the repo
    /// unfinished, and only finished bytes count towards the size check.
    private func blobBytes(in blobs: URL) -> (total: Int64, finished: Int64, hasIncomplete: Bool) {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: blobs.path)
        } catch {
            // No blobs directory is not a failure — it is the answer: this model
            // has never been fetched on this machine.
            return (0, 0, false)
        }
        var total: Int64 = 0
        var finished: Int64 = 0
        var hasIncomplete = false
        for name in names {
            let size = fileSize(at: blobs.appendingPathComponent(name))
            total += size
            if name.hasSuffix(".incomplete") {
                hasIncomplete = true
            } else {
                finished += size
            }
        }
        return (total, finished, hasIncomplete)
    }

    /// A blob's length, or zero when it can't be read — a blob that disappeared
    /// between the listing and the stat (the hub prunes as it downloads) is one
    /// that isn't contributing bytes.
    private func fileSize(at file: URL) -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            return 0
        }
    }

    /// True when some revision snapshot has a `config.json` that resolves to real
    /// bytes. `fileExists` follows symlinks, so a snapshot pointing at a blob that
    /// was never finished (or has since been pruned) reads as absent, which is
    /// exactly the answer wanted.
    private func hasResolvableConfig(in snapshots: URL) -> Bool {
        let revisions: [String]
        do {
            revisions = try FileManager.default.contentsOfDirectory(atPath: snapshots.path)
        } catch {
            // Blobs but no snapshots: a download that stopped before it linked
            // anything up.
            return false
        }
        return revisions.contains { revision in
            FileManager.default.fileExists(
                atPath: snapshots
                    .appendingPathComponent(revision)
                    .appendingPathComponent("config.json").path
            )
        }
    }
}
