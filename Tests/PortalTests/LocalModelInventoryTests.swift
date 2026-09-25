import Foundation
import Testing
@testable import Portal

/// A Hugging Face hub cache on disk, so the scanner can be pointed at something
/// real without downloading anything.
///
/// The blobs are sparse files — truncated to a length, never written — so a
/// "17 GB" model costs no disk and no time. That matters: the scanner's
/// completeness check is a size comparison, and faking the sizes away would test
/// nothing.
internal struct FakeHubCache {
    internal let root: URL

    internal init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("portal-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    internal func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    internal var scanner: LocalModelCacheScanner { LocalModelCacheScanner(root: root) }

    /// A finished download: weight and config blobs of the real size, with a
    /// snapshot of relative symlinks into them, exactly as the hub lays it out.
    internal func install(_ model: LocalChatModel, bytes: Int64? = nil) throws {
        let blobs = try makeBlobs(for: model, weightBytes: bytes ?? model.downloadBytes)
        try link(model, weightBlob: blobs.weight, configBlob: blobs.config)
    }

    /// A download that stopped partway: some finished blobs, one still
    /// `.incomplete`, and a snapshot that hasn't been written yet.
    internal func installPartial(_ model: LocalChatModel, finished: Int64) throws {
        let blobs = try makeBlobs(for: model, weightBytes: finished)
        try truncate(blobs.weight.appendingPathExtension("incomplete"), to: 1_000_000)
    }

    /// Blobs and a snapshot, but the snapshot's symlinks point at bytes that
    /// aren't there — what a pruned or interrupted cache looks like.
    internal func installDangling(_ model: LocalChatModel) throws {
        let blobs = try makeBlobs(for: model, weightBytes: model.downloadBytes)
        try link(model, weightBlob: blobs.weight, configBlob: blobs.config)
        try FileManager.default.removeItem(at: blobs.config)
    }

    private func repository(_ model: LocalChatModel) -> URL {
        root.appendingPathComponent(
            LocalModelCacheScanner.directoryName(forRepository: model.repositoryID)
        )
    }

    private func makeBlobs(for model: LocalChatModel, weightBytes: Int64) throws -> (weight: URL, config: URL) {
        let blobs = repository(model).appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let weight = blobs.appendingPathComponent("weightblob")
        let config = blobs.appendingPathComponent("configblob")
        try truncate(weight, to: weightBytes)
        try truncate(config, to: 4_096)
        return (weight, config)
    }

    private func link(_ model: LocalChatModel, weightBlob: URL, configBlob: URL) throws {
        let snapshot = repository(model)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("0123456789abcdef")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("config.json").path,
            withDestinationPath: "../../blobs/\(configBlob.lastPathComponent)"
        )
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/\(weightBlob.lastPathComponent)"
        )
    }

    private func truncate(_ file: URL, to bytes: Int64) throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }
}

@Suite("Local model cache scanner")
internal struct LocalModelCacheScannerTests {

    @Test("repo IDs map onto the hub's directory names")
    internal func mangledDirectoryNames() {
        #expect(
            LocalModelCacheScanner.directoryName(forRepository: "mlx-community/Qwen3-4B-4bit")
                == "models--mlx-community--Qwen3-4B-4bit"
        )
        // Hyphens and dots inside the name are left alone; only the slash is
        // rewritten. Get this wrong and every model reads as a pending download.
        #expect(
            LocalModelCacheScanner.directoryName(forRepository: "mlx-community/LFM2-8B-A1B-3bit-MLX")
                == "models--mlx-community--LFM2-8B-A1B-3bit-MLX"
        )
    }

    @Test("the cache root is resolved the way the downloader resolves it")
    internal func cacheRootPriority() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let caches = URL(fileURLWithPath: "/Users/tester/Library/Caches", isDirectory: true)
        func root(_ environment: [String: String]) -> String {
            LocalModelCacheScanner.defaultRoot(
                environment: environment, homeDirectory: home, cachesDirectory: caches
            ).path
        }
        // Explicit hub cache wins outright.
        #expect(root(["HF_HUB_CACHE": "/weights", "HF_HOME": "/hf"]) == "/weights")
        // HF_HOME is a *home*, so the hub lives in a subdirectory of it.
        #expect(root(["HF_HOME": "/hf"]) == "/hf/hub")
        #if os(macOS)
        // The shared location, which is what makes weights fetched by the Python
        // CLI (or by this app's skill summarizer) count as already downloaded.
        #expect(root([:]) == "/Users/tester/.cache/huggingface/hub")
        // Sandboxed, ~/.cache is unreachable and the hub uses the container.
        #expect(
            root(["APP_SANDBOX_CONTAINER_ID": "com.ethenotethan.Portal"])
                == "/Users/tester/Library/Caches/huggingface/hub"
        )
        #endif
    }

    @Test("a finished download reads as downloaded")
    internal func findsInstalledModels() throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        try cache.install(.gemma3_1b)
        try cache.install(.qwen3_4b)

        let inventory = cache.scanner.scan()
        #expect(inventory.isDownloaded(.gemma3_1b))
        #expect(inventory.isDownloaded(.qwen3_4b))
        #expect(!inventory.isDownloaded(.qwen3_30b_a3b))
        // Lineup order, not dictionary order — this string is user-visible.
        #expect(inventory.downloadedModels == [.gemma3_1b, .qwen3_4b])
        #expect(inventory.presence(of: .qwen3_30b_a3b) == .absent)
    }

    @Test("a half-finished download is not a model")
    internal func partialDownloadIsNotDownloaded() throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        // 90% of the bytes are there, which would pass a size check on its own —
        // the `.incomplete` blob is what gives it away, and answering "downloaded"
        // here would promise an instant reply and then stall on a resume.
        try cache.installPartial(.qwen3_4b, finished: Int64(Double(LocalChatModel.qwen3_4b.downloadBytes) * 0.9))

        let inventory = cache.scanner.scan()
        #expect(!inventory.isDownloaded(.qwen3_4b))
        // Still reported as disk in use: those bytes are real, and this is where
        // the user goes looking for them.
        #expect(inventory.presence(of: .qwen3_4b).bytesOnDisk > 0)
    }

    @Test("a snapshot whose weights were pruned is not a model")
    internal func danglingSnapshotIsNotDownloaded() throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        try cache.installDangling(.qwen3_8b)
        #expect(!cache.scanner.scan().isDownloaded(.qwen3_8b))
    }

    @Test("a truncated model that kept its symlinks is not a model")
    internal func shortWeightsAreNotDownloaded() throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        // Everything resolves and nothing is marked incomplete, but a third of the
        // weights are missing — one shard of a sharded repo never arrived.
        try cache.install(.qwen3_30b_a3b, bytes: LocalChatModel.qwen3_30b_a3b.downloadBytes / 3)
        let inventory = cache.scanner.scan()
        #expect(!inventory.isDownloaded(.qwen3_30b_a3b))
        #expect(inventory.presence(of: .qwen3_30b_a3b).bytesOnDisk > 0)
    }

    @Test("an empty cache reports nothing rather than failing")
    internal func emptyCache() throws {
        let cache = try FakeHubCache()
        defer { cache.remove() }
        let inventory = cache.scanner.scan()
        #expect(inventory.downloadedModels.isEmpty)
        #expect(inventory.totalBytesOnDisk == 0)
        #expect(inventory.summary == nil)
        // No cache directory at all — a fresh machine, or iOS.
        #expect(LocalModelCacheScanner(root: nil).scan() == .unknown)
    }

    @Test("this machine can be scanned")
    internal func scansThisMachine() {
        // Not asserting contents — CI has no weights and a developer's Mac has
        // gigabytes of them. The point is that the real root resolves and the scan
        // returns rather than throwing or hanging.
        let inventory = LocalModelCacheScanner.current().scan()
        #expect(inventory.totalBytesOnDisk >= 0)
    }
}

@Suite("Local model inventory")
internal struct LocalModelInventoryTests {

    private static func inventory(_ downloaded: [LocalChatModel], bytesEach: Int64) -> LocalModelInventory {
        LocalModelInventory(
            presence: Dictionary(
                uniqueKeysWithValues: downloaded.map {
                    ($0, LocalModelPresence(isDownloaded: true, bytesOnDisk: bytesEach))
                }
            )
        )
    }

    @Test("the on-disk line names the models and the space")
    internal func summarizesWhatIsOnDisk() {
        let inventory = Self.inventory([.qwen3_4b, .gemma3_1b], bytesEach: 1_500_000_000)
        #expect(inventory.summary == "Gemma 3 1B, Qwen3 4B (3.0 GB)")
        #expect(inventory.totalBytesOnDisk == 3_000_000_000)
        #expect(LocalModelInventory.unknown.summary == nil)
    }

    @Test("each row says whether picking it costs a download")
    internal func statusPerModel() {
        let inventory = Self.inventory([.gemma3_1b], bytesEach: 730_000_000)
        #expect(inventory.status(of: .gemma3_1b) == "downloaded")
        #expect(inventory.status(of: .qwen3_30b_a3b) == "~17.2 GB to fetch")
        // Before the first scan every row reads as a fetch, which is the safe way
        // round: it over-warns rather than promising an instant model.
        #expect(LocalModelInventory.unknown.status(of: .gemma3_1b) == "~0.7 GB to fetch")
    }

    @Test("gigabytes are decimal, matching what the model page says")
    internal func formatsGigabytes() {
        #expect(ByteCountLabel.gigabytes(730_000_000) == "0.7 GB")
        #expect(ByteCountLabel.gigabytes(17_170_000_000) == "17.2 GB")
        #expect(ByteCountLabel.gigabytes(0) == "0.0 GB")
    }
}
