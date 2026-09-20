import Foundation

/// Where an on-device neural voice is in its life: nothing loaded yet, the
/// weights downloading or loading, ready to speak, or a load that failed with
/// a reason worth showing in Settings.
internal enum NeuralSpeechState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case failed(String)

    internal var isReady: Bool { self == .ready }
}

/// What a neural voice reports back about an utterance it was handed. The
/// same three moments `AVSpeechSynthesizer`'s delegate marks, so `TTSService`
/// can treat both engines as one queue.
internal enum NeuralSpeechEvent: Equatable, Sendable {
    /// The first audio of the utterance is playing.
    case started(UUID)
    /// The last audio of the utterance has played, or it was cancelled.
    case finished(UUID)
    /// Synthesis failed before or during playback; nothing more will be heard.
    case failed(UUID, String)
}

/// One selectable neural voice: the id the model loads it by (a
/// `<voice>.safetensors` in the language pack) and a display name for the
/// picker. Every voice in the pack ships together, so any option here resolves
/// locally once the model has loaded — there is no per-voice download to fail.
internal struct NeuralVoiceOption: Identifiable, Hashable, Sendable {
    internal let id: String
    internal let name: String
}

/// Text-to-speech from an on-device neural model, as `TTSService` drives it.
///
/// The system voice speaks through `SpeechSynthesizing`, a slice of
/// `AVSpeechSynthesizer`. A neural model is a different kind of thing: it has
/// to be downloaded and loaded before it can say anything, it renders audio
/// samples rather than owning playback, and it knows nothing about
/// `AVSpeechUtterance`. This seam is the smallest surface the service needs
/// from such a model — prepare, speak this text under this id, and the
/// transport controls — with every result delivered as a callback on the main
/// actor. A protocol so the service can be tested with a recorder, and so the
/// real implementation (FluidAudio's PocketTTS, in `NeuralSpeechEngine.swift`)
/// stays out of the SwiftPM test build.
@MainActor
internal protocol NeuralSpeechSynthesizing: AnyObject {
    /// Set by the service; called on the main actor whenever the load state
    /// changes, so Settings can show "Loading…" / "ready" / the error.
    var onStateChange: ((NeuralSpeechState) -> Void)? { get set }
    /// Set by the service; called on the main actor for every utterance event.
    var onEvent: ((NeuralSpeechEvent) -> Void)? { get set }
    /// Set by the service; called on the main actor with the live 0...1 loudness
    /// of the audio actually leaving the engine, so the conversation orb can
    /// breathe with the assistant's own voice while it speaks (0 when silent).
    var onOutputLevel: ((Float) -> Void)? { get set }
    /// The voices this model can speak in, for the Settings picker. Empty when
    /// the build links no neural voice at all.
    var availableVoices: [NeuralVoiceOption] { get }
    /// The selected voice's id (a member of `availableVoices`). Takes effect on
    /// the next utterance — the model reads the voice per synthesis call.
    var voice: String { get set }
    /// Persona "warmth" as a pitch shift in cents (negative is deeper/warmer),
    /// applied with the same time-pitch unit as `rate` so it is voice-model
    /// independent. 0 is the model's natural pitch.
    var pitch: Float { get set }
    /// Current load state. `.ready` is the only state in which `speak` is heard.
    var state: NeuralSpeechState { get }
    /// Download (first run) and load the model in the background. Idempotent
    /// while a load is running or already done.
    func prepare()
    /// Queue `text` behind whatever is already speaking. `rate` is a multiple
    /// of the natural speaking rate (`0.5 ... 2.0`).
    func speak(_ text: String, id: UUID, rate: Double)
    /// Silence everything queued and playing. Every utterance still in flight
    /// reports `.finished`.
    func stop()
    /// Hold playback. Returns false when nothing is playing.
    @discardableResult func pause() -> Bool
    /// Resume held playback. Returns false when nothing was paused.
    @discardableResult func resume() -> Bool
}
