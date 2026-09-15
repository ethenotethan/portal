import AVFoundation
import Combine
import Foundation

/// Microphone capture seam. The real implementation (AVAudioEngine) lives in
/// `LocalVoiceEngine.swift` behind `#if canImport(FluidAudio)`, so tests inject
/// a fake and drive the orchestration without an audio device.
@MainActor
internal protocol MicrophoneCapturing: AnyObject {
    /// Begin capture, forwarding every buffer to `transcriber`. The real
    /// implementation does the (non-Sendable) buffer plumbing off the main
    /// actor, so the orchestration core never touches raw audio.
    func start(feeding transcriber: any LocalSpeechTranscribing) throws
    func stop()
}

/// On-device streaming ASR seam. The real implementation wraps FluidAudio's
/// Parakeet EOU streaming engine (`StreamingEouAsrManager`); tests inject a fake
/// so no CoreML model download is needed to exercise the service.
internal protocol LocalSpeechTranscribing: AnyObject, Sendable {
    /// Download (first run) and load the model into memory. Idempotent.
    func loadModels() async throws
    /// Register the live partial-transcript callback (text as the user speaks).
    func onPartial(_ handler: @escaping @Sendable (String) -> Void) async
    /// Register the end-of-utterance callback (the user stopped speaking).
    func onEndOfUtterance(_ handler: @escaping @Sendable () -> Void) async
    /// Feed one captured audio buffer and process any complete chunks.
    func append(_ buffer: AVAudioPCMBuffer) async
    /// Flush remaining audio and return the final transcript for the utterance.
    func finish() async throws -> String
    /// Clear decode/buffer state for the next utterance (models stay loaded).
    func reset() async
}

/// The slice of the local-voice service `ChatViewModel` drives. A protocol so
/// the view model can be tested with a fake, decoupled from the shared
/// singleton and any real microphone.
@MainActor
internal protocol LocalVoiceControlling: AnyObject {
    /// True when the user opted in AND this build/device can transcribe locally.
    var isEnabledAndAvailable: Bool { get }
    /// Whether a capture session is currently active.
    var isRunning: Bool { get }
    /// Set by the view model; fired on the main actor with the final transcript
    /// once an utterance ends (via end-of-utterance detection or `stop()`).
    var onFinalTranscript: ((String) -> Void)? { get set }
    func start() async
    func stop() async
}

/// On-device speech-to-text for the walkie-talkie mic button, mirroring how
/// `TTSService` owns on-device text-to-speech.
///
/// Off by default and opt-in (Settings → Speech). When enabled on a supported
/// build, the mic button captures audio locally and transcribes it with
/// Parakeet TDT via FluidAudio — nothing leaves the device — instead of
/// streaming to the gateway's faster-whisper. When the on-device engine isn't
/// linked (`isAvailable == false`), the mic falls back to the gateway path.
///
/// This file is the testable orchestration core: it imports no ML framework and
/// talks to the mic and transcriber only through protocol seams. The real
/// FluidAudio/AVAudioEngine implementations live in `LocalVoiceEngine.swift`.
@MainActor
internal final class LocalVoiceService: ObservableObject, LocalVoiceControlling {
    // swiftlint:disable:next no_new_singletons
    internal static let shared = LocalVoiceService()

    internal static let enabledKey = "portal.localVoiceEnabled"

    /// User opt-in. Off by default. Persisted like `TTSService`'s settings so
    /// there's no second copy of the state to drift.
    @Published internal var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Live partial transcript, for optional UI display while recording.
    @Published internal private(set) var partialTranscript: String = ""

    @Published internal private(set) var isRunning: Bool = false

    /// Set by `ChatViewModel`; fired on the main actor when an utterance ends.
    internal var onFinalTranscript: ((String) -> Void)?

    /// nil when the build has no on-device engine (FluidAudio not linked, or an
    /// unsupported platform) — the mic button then uses the gateway instead.
    private let transcriber: LocalSpeechTranscribing?
    private let microphone: MicrophoneCapturing?
    /// Injected so tests can grant/deny without a real permission prompt.
    private let requestPermission: @Sendable () async -> Bool

    private var didLoadModels = false

    internal init(
        transcriber: LocalSpeechTranscribing? = LocalVoiceService.defaultTranscriber(),
        microphone: MicrophoneCapturing? = LocalVoiceService.defaultMicrophone(),
        requestPermission: @escaping @Sendable () async -> Bool = LocalVoiceService.defaultPermission
    ) {
        self.transcriber = transcriber
        self.microphone = microphone
        self.requestPermission = requestPermission
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// Whether this build can transcribe on-device at all (engine linked +
    /// microphone available). Independent of the user's opt-in.
    internal var isAvailable: Bool { transcriber != nil && microphone != nil }

    internal var isEnabledAndAvailable: Bool { isEnabled && isAvailable }

    /// Begin capturing and transcribing. No-op unless enabled, available, idle,
    /// and microphone permission is granted.
    internal func start() async {
        guard isEnabledAndAvailable, !isRunning,
              let transcriber, let microphone else { return }
        guard await requestPermission() else { return }
        do {
            if !didLoadModels {
                try await transcriber.loadModels()
                didLoadModels = true
            }
            await transcriber.reset()
            partialTranscript = ""
            await transcriber.onPartial { [weak self] text in
                Task { @MainActor in self?.partialTranscript = text }
            }
            await transcriber.onEndOfUtterance { [weak self] in
                Task { @MainActor in await self?.finishUtterance() }
            }
            try microphone.start(feeding: transcriber)
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    /// Stop the current utterance and emit its transcript, if any.
    internal func stop() async {
        guard isRunning else { return }
        await finishUtterance()
    }

    /// Tear down capture, flush the transcript, and fire `onFinalTranscript`.
    /// Guarded on `isRunning` so end-of-utterance and a manual `stop()` racing
    /// each other only finalize once.
    private func finishUtterance() async {
        guard isRunning, let transcriber, let microphone else { return }
        isRunning = false
        microphone.stop()
        let text: String
        do {
            text = try await transcriber.finish()
        } catch {
            // Fall back to the last partial if the flush fails — better a rough
            // transcript than a dropped utterance.
            text = partialTranscript
        }
        await transcriber.reset()
        partialTranscript = ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            onFinalTranscript?(trimmed)
        }
    }
}

// MARK: - Default engine wiring

extension LocalVoiceService {
    #if canImport(FluidAudio)
    internal static func defaultTranscriber() -> LocalSpeechTranscribing? { FluidAudioTranscriber() }
    internal static func defaultMicrophone() -> MicrophoneCapturing? { AVAudioEngineMicrophone() }
    internal static func defaultPermission() async -> Bool { await AVAudioEngineMicrophone.requestPermission() }
    #else
    /// No on-device engine linked in this build — local voice is unavailable.
    internal static func defaultTranscriber() -> LocalSpeechTranscribing? { nil }
    internal static func defaultMicrophone() -> MicrophoneCapturing? { nil }
    internal static func defaultPermission() async -> Bool { false }
    #endif
}
