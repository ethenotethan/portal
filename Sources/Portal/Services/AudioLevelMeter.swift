import Combine
import Foundation

/// A smoothed 0...1 audio loudness that publishes on its own.
///
/// Mic and speaker levels arrive roughly ten times a second for as long as a
/// hands-free conversation is open. When that level lived as `@Published` state
/// on `ChatViewModel` (and `TTSService`), every sample fired `objectWillChange`
/// on the object the whole transcript observes, so the entire chat canvas
/// re-rendered ten times a second while the user was merely listening — the
/// idle 100%-CPU storm recorded by the session health watchdog on long runs.
/// Keeping the level on this small object lets the orb alone observe it.
@MainActor
internal final class AudioLevelMeter: ObservableObject {
    @Published internal private(set) var level: Float = 0

    internal init() {}

    /// Fold one raw per-buffer sample in with an exponential moving average so
    /// the orb pulses smoothly instead of strobing with buffer jitter.
    internal func fold(_ raw: Float) {
        let clamped = max(0, min(1, raw))
        level = level * 0.7 + clamped * 0.3
    }

    internal func reset() {
        guard level != 0 else { return }
        level = 0
    }
}
