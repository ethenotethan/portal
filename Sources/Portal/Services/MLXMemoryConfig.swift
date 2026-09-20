import Foundation
import MLX
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "MLXMemoryConfig")

/// A process-wide bound on MLX's Metal buffer cache.
///
/// MLX recycles GPU buffers rather than freeing them: intermediate tensors from
/// inference are parked in a reuse pool that, left alone, grows to a large
/// fraction of the device's working set (see MLX's own note that "by the end of
/// a long inference run, you may see several GB of cached memory ... if cache
/// memory is unconstrained"). Portal drives *two* MLX consumers into that one
/// process-global pool — the on-device chat model behind the local-discussion
/// pane (`MLXLocalChatEngine`) and the neural voice (`PocketTtsSpeechEngine`) —
/// and over a long spoken conversation it had grown past 17 GB of otherwise-idle
/// graphics memory, enough to starve the GPU and make the app hang.
///
/// Capping the *cache* leaves buffer reuse working and does not touch active
/// memory: model weights and the live KV cache are counted as active, not
/// cached, so bounding the reclaimable pool costs a little reuse but not
/// correctness or the resident model.
internal enum MLXMemoryConfig {

    /// Ceiling on the reclaimable buffer cache. Active model memory (weights,
    /// KV cache) is unaffected — this only bounds the reuse pool. 512 MB keeps
    /// enough for same-size buffers to be recycled across tokens while stopping
    /// the pool from hoarding gigabytes.
    private static let cacheLimitBytes = 512 * 1024 * 1024

    /// Runs once, the first time any MLX path is entered. `static let` gives us
    /// thread-safe, exactly-once initialization.
    private static let applyOnce: Void = {
        MLX.Memory.cacheLimit = cacheLimitBytes
        log.info("MLX cache limit set to \(cacheLimitBytes / (1024 * 1024)) MB")
    }()

    /// Bound the MLX buffer cache. Idempotent and cheap; call it before any MLX
    /// allocation (model load, synthesis) so the cap is in force from the start.
    internal static func configureIfNeeded() {
        _ = applyOnce
    }

    /// Release the reclaimable cache now, returning that graphics memory to the
    /// system. Called when an MLX-backed feature goes idle (a discussion ends),
    /// so the pool doesn't sit at its ceiling between conversations. Active
    /// memory is untouched, so a still-loaded model keeps working.
    internal static func reclaim() {
        MLX.Memory.clearCache()
    }
}
