import Foundation
import os
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS)
import AVFAudio
#endif

private let log = PortalLogger(category: "SpeechPlaybackSession")

/// A transport control that arrived from outside the app: the lock screen, a
/// headphone button, the Mac's media keys, or the Now Playing widget.
internal enum SpeechRemoteCommand: Equatable {
    case play
    case pause
    case togglePlayPause
    case stop
}

/// The platform side of speaking aloud: owning the audio session so speech
/// keeps going when the phone locks, and publishing what's being read to the
/// system's Now Playing surface so it can be paused from anywhere.
///
/// A protocol because `TTSService` is unit-tested and none of this can run in
/// a test process (no audio route, no Now Playing center to observe). The
/// service talks to the seam; the app installs `SystemSpeechPlaybackSession`.
@MainActor
internal protocol SpeechPlaybackSessioning: AnyObject {
    /// Set by the service; called on the main actor for every remote command.
    var onRemoteCommand: ((SpeechRemoteCommand) -> Void)? { get set }
    /// Speech is about to start: claim the audio route.
    func activate()
    /// Speech has finished or was stopped: release it and clear Now Playing.
    func deactivate()
    /// Describe what's being read right now.
    func updateNowPlaying(title: String, detail: String?, isPlaying: Bool)
}

/// The real thing. On iOS it configures `AVAudioSession` for spoken audio
/// (ducking music rather than stopping it) and, with the `audio` background
/// mode declared in Info.plist, keeps speaking after the screen locks. On both
/// platforms it drives `MPNowPlayingInfoCenter` and answers
/// `MPRemoteCommandCenter` — that is what puts pause/play on the lock screen,
/// on AirPods, and under the Mac's media keys.
@MainActor
internal final class SystemSpeechPlaybackSession: SpeechPlaybackSessioning {
    internal var onRemoteCommand: ((SpeechRemoteCommand) -> Void)?
    private var commandsInstalled = false

    internal init() {}

    internal func activate() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            log.error("Audio session activation failed: \(error.localizedDescription)")
        }
        #endif
        installRemoteCommandsIfNeeded()
    }

    internal func deactivate() {
        #if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        #endif
        #endif
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Common and harmless: another player already owns the route.
            log.debug("Audio session deactivation: \(error.localizedDescription)")
        }
        #endif
    }

    internal func updateNowPlaying(title: String, detail: String?, isPlaying: Bool) {
        #if canImport(MediaPlayer)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: "Portal",
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if let detail, !detail.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = detail
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        #if os(macOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
        #endif
    }

    private func installRemoteCommandsIfNeeded() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        #if canImport(MediaPlayer)
        let center = MPRemoteCommandCenter.shared()
        bind(center.playCommand, to: .play)
        bind(center.pauseCommand, to: .pause)
        bind(center.togglePlayPauseCommand, to: .togglePlayPause)
        bind(center.stopCommand, to: .stop)
        // Speech has no timeline to seek in; leave those controls off so the
        // lock screen shows a plain pause/play.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        #endif
    }

    #if canImport(MediaPlayer)
    private func bind(_ command: MPRemoteCommand, to remote: SpeechRemoteCommand) {
        command.isEnabled = true
        command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onRemoteCommand?(remote)
            }
            return .success
        }
    }
    #endif
}

/// For tests and previews: records calls, performs none.
@MainActor
internal final class RecordingSpeechPlaybackSession: SpeechPlaybackSessioning {
    internal var onRemoteCommand: ((SpeechRemoteCommand) -> Void)?
    internal private(set) var activations = 0
    internal private(set) var deactivations = 0
    internal private(set) var nowPlaying: [(title: String, detail: String?, isPlaying: Bool)] = []

    internal init() {}

    internal func activate() { activations += 1 }
    internal func deactivate() { deactivations += 1 }
    internal func updateNowPlaying(title: String, detail: String?, isPlaying: Bool) {
        nowPlaying.append((title, detail, isPlaying))
    }
}
