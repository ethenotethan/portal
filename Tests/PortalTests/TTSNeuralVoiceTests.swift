import AVFoundation
import Foundation
import Testing
@testable import Portal

/// A neural voice that records what it was asked to say and lets a test play
/// the load state and the utterance events back by hand.
@MainActor
private final class RecordingNeuralSynthesizer: NeuralSpeechSynthesizing {
    var onStateChange: ((NeuralSpeechState) -> Void)?
    var onEvent: ((NeuralSpeechEvent) -> Void)?
    var onOutputLevel: ((Float) -> Void)?
    let availableVoices: [NeuralVoiceOption] = [
        NeuralVoiceOption(id: "alba", name: "Alba"),
        NeuralVoiceOption(id: "michael", name: "Michael")
    ]
    var voice = "alba"
    var pitch: Float = 0
    var state: NeuralSpeechState = .idle {
        didSet { onStateChange?(state) }
    }

    var spoken: [(id: UUID, text: String, rate: Double)] = []
    var inFlight: [UUID] = []
    var prepares = 0
    var stops = 0
    var isPaused = false

    /// Idempotent once loaded, like the real engine.
    func prepare() {
        guard state != .ready else { return }
        prepares += 1
        state = .preparing
    }

    func speak(_ text: String, id: UUID, rate: Double) {
        spoken.append((id, text, rate))
        inFlight.append(id)
    }

    /// Like the real engine: everything silenced reports finished.
    func stop() {
        stops += 1
        isPaused = false
        let silenced = inFlight
        inFlight.removeAll()
        for id in silenced { onEvent?(.finished(id)) }
    }

    func pause() -> Bool {
        guard !inFlight.isEmpty, !isPaused else { return false }
        isPaused = true
        return true
    }

    func resume() -> Bool {
        guard isPaused else { return false }
        isPaused = false
        return true
    }

    // Playback of the events, as the real engine would drive them.
    func fireStart(_ index: Int) { onEvent?(.started(spoken[index].id)) }
    func fireFinish(_ index: Int) {
        inFlight.removeAll { $0 == spoken[index].id }
        onEvent?(.finished(spoken[index].id))
    }
    func fireFail(_ index: Int) {
        inFlight.removeAll { $0 == spoken[index].id }
        onEvent?(.failed(spoken[index].id, "model hiccup"))
    }
}

/// The system synthesizer, as a bystander: the tests only need to know
/// whether it was handed anything.
private final class BystanderSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    var isSpeaking = false
    var isPaused = false
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    var spoken: [AVSpeechUtterance] = []
    var stops = 0
    var pauses = 0

    func speak(_ utterance: AVSpeechUtterance) {
        spoken.append(utterance)
        isSpeaking = true
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        isSpeaking = false
        isPaused = false
        return true
    }

    func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        pauses += 1
        isPaused = true
        return true
    }

    func continueSpeaking() -> Bool {
        isPaused = false
        return true
    }
}

@MainActor
@Suite("TTS service: neural voice")
internal struct TTSNeuralVoiceTests {

    private struct Rig {
        let synth: BystanderSynthesizer
        let neural: RecordingNeuralSynthesizer
        let playback: RecordingSpeechPlaybackSession
        let service: TTSService
        let defaults: UserDefaults
    }

    private func rig(neuralOn: Bool = true, ready: Bool = true) -> Rig {
        let suite = "tts-neural-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let synth = BystanderSynthesizer()
        let neural = RecordingNeuralSynthesizer()
        let playback = RecordingSpeechPlaybackSession()
        let service = TTSService(synthesizer: synth, playback: playback, defaults: defaults, neural: neural)
        service.isEnabled = true
        service.utteranceTargetLength = 0
        service.usesNeuralVoice = neuralOn
        if ready { neural.state = .ready }
        return Rig(synth: synth, neural: neural, playback: playback, service: service, defaults: defaults)
    }

    private func message(_ content: String) -> ChatMessage {
        ChatMessage(id: UUID(), role: .assistant, content: content, isStreaming: false)
    }

    // MARK: Availability and setting

    @Test("without a linked neural voice the setting has nothing to switch to")
    internal func unavailableWithoutEngine() {
        let synth = BystanderSynthesizer()
        let defaults = UserDefaults(suiteName: "tts-neural-none-\(UUID().uuidString)") ?? .standard
        let service = TTSService(synthesizer: synth, playback: RecordingSpeechPlaybackSession(), defaults: defaults)
        service.isEnabled = true
        #expect(!service.isNeuralVoiceAvailable)
        service.usesNeuralVoice = true
        #expect(!service.speaksWithNeuralVoice)
        service.speak("Still the system voice.")
        #expect(synth.spoken.count == 1)
    }

    @Test("the neural voice is off by default, persists, and a restored choice starts loading at launch")
    internal func settingPersistsAndReloads() {
        let r = rig(neuralOn: false, ready: false)
        #expect(!r.service.usesNeuralVoice)
        #expect(r.neural.prepares == 0)
        r.service.usesNeuralVoice = true
        #expect(r.neural.prepares == 1)

        let neuralAgain = RecordingNeuralSynthesizer()
        let reloaded = TTSService(synthesizer: BystanderSynthesizer(), playback: RecordingSpeechPlaybackSession(), defaults: r.defaults, neural: neuralAgain)
        #expect(reloaded.usesNeuralVoice)
        #expect(neuralAgain.prepares == 1, "a voice chosen last session loads without a toggle being touched")
        #expect(reloaded.neuralState == .preparing)
    }

    @Test("turning the voice on starts the load and the service mirrors the engine's state")
    internal func loadStateMirrors() {
        let r = rig(neuralOn: false, ready: false)
        r.service.usesNeuralVoice = true
        #expect(r.service.neuralState == .preparing)
        #expect(!r.service.speaksWithNeuralVoice)
        r.neural.state = .ready
        #expect(r.service.neuralState == .ready)
        #expect(r.service.speaksWithNeuralVoice)
        r.neural.state = .failed("no disk")
        #expect(r.service.neuralState == .failed("no disk"))
        #expect(!r.service.speaksWithNeuralVoice)
    }

    // MARK: Persona

    @Test("the chosen voice is pushed to the engine, persists, and reloads next launch")
    internal func voiceChoicePersists() {
        let r = rig()
        #expect(r.neural.voice == "alba", "the model's default until a choice is made")
        r.service.neuralVoice = "michael"
        #expect(r.neural.voice == "michael")

        let neuralAgain = RecordingNeuralSynthesizer()
        let reloaded = TTSService(synthesizer: BystanderSynthesizer(), playback: RecordingSpeechPlaybackSession(), defaults: r.defaults, neural: neuralAgain)
        #expect(reloaded.neuralVoice == "michael")
        #expect(neuralAgain.voice == "michael", "the restored voice is handed to the engine at launch")
    }

    @Test("switching voice mid-reply stops what was rendered for the old one")
    internal func switchingVoiceStops() {
        let r = rig()
        r.service.speak("Old voice.")
        #expect(r.neural.inFlight.count == 1)
        r.service.neuralVoice = "george"
        #expect(r.neural.stops == 1)
        #expect(!r.service.isActive)
    }

    @Test("warmth maps to a pitch shift on the engine and persists")
    internal func warmthMapsToPitch() {
        let r = rig()
        #expect(r.neural.pitch == 0)
        r.service.warmth = 1.0
        #expect(r.neural.pitch == -250, "warmest deepens the voice")
        r.service.warmth = -1.0
        #expect(r.neural.pitch == 250, "brightest raises it")

        let neuralAgain = RecordingNeuralSynthesizer()
        let reloaded = TTSService(synthesizer: BystanderSynthesizer(), playback: RecordingSpeechPlaybackSession(), defaults: r.defaults, neural: neuralAgain)
        #expect(reloaded.warmth == -1.0)
        #expect(neuralAgain.pitch == 250, "the restored warmth is applied at launch")
    }

    // MARK: Routing

    @Test("while the model loads, speech falls back to the system voice; once ready it goes neural")
    internal func fallsBackWhileLoading() {
        let r = rig(ready: false)
        r.service.speak("Early.")
        #expect(r.synth.spoken.map(\.speechString) == ["Early."])
        #expect(r.neural.spoken.isEmpty)
        r.service.stop()

        r.neural.state = .ready
        r.service.rateMultiplier = 1.4
        r.service.speak("Later.")
        #expect(r.synth.spoken.count == 1, "nothing new for the system voice")
        #expect(r.neural.spoken.map(\.text) == ["Later."])
        #expect(r.neural.spoken.first?.rate == 1.4)
        #expect(r.playback.activations == 2)
    }

    @Test("the neural voice is handed every streamed sentence as it closes, whatever the batch length")
    internal func streamsPerSentence() {
        let r = rig()
        r.service.streamingBatchLength = 1000
        let id = UUID()
        r.service.streamDelta("One two. Three ", messageID: id)
        #expect(r.neural.spoken.map(\.text) == ["One two."])
        r.service.streamDelta("four. Tail", messageID: id)
        #expect(r.neural.spoken.map(\.text) == ["One two.", "Three four."])
        r.service.finishStreaming(messageID: id)
        #expect(r.neural.spoken.map(\.text) == ["One two.", "Three four.", "Tail"])
        #expect(r.synth.spoken.isEmpty)
    }

    @Test("with the neural voice off, batching and the system voice behave as before")
    internal func systemPathUnchanged() {
        let r = rig(neuralOn: false)
        r.service.streamingBatchLength = 25
        let id = UUID()
        r.service.streamDelta("One two. ", messageID: id)
        #expect(r.synth.spoken.isEmpty)
        r.service.streamDelta("Three four five six. ", messageID: id)
        #expect(r.synth.spoken.map(\.speechString) == ["One two. Three four five six."])
        #expect(r.neural.spoken.isEmpty)
        r.service.pause()
        #expect(r.synth.pauses == 1)
        #expect(!r.neural.isPaused)
    }

    // MARK: Lifecycle

    @Test("engine events drive the current sentence, pause, Now Playing, and settle when the queue drains")
    internal func eventsDriveLifecycle() {
        let r = rig()
        let msg = message("One. Two.")
        r.service.speakMessage(msg)
        #expect(r.neural.spoken.map(\.text) == ["One.", "Two."])
        #expect(r.service.isSpeaking)
        #expect(r.service.speakingMessageID == msg.id)

        r.neural.fireStart(0)
        #expect(r.service.currentSentence == "One.")
        #expect(r.playback.nowPlaying.last?.detail == "One.")

        r.service.pause()
        #expect(r.service.isPaused)
        #expect(r.neural.isPaused)
        #expect(r.synth.pauses == 0)
        #expect(r.playback.nowPlaying.last?.title == "Paused")
        r.service.resume()
        #expect(!r.service.isPaused)
        #expect(!r.neural.isPaused)

        r.neural.fireFinish(0)
        #expect(r.service.isSpeaking, "second sentence still queued")
        r.neural.fireStart(1)
        #expect(r.service.currentSentence == "Two.")
        r.neural.fireFinish(1)
        #expect(!r.service.isSpeaking)
        #expect(r.service.currentSentence == nil)
        #expect(r.service.speakingMessageID == nil)
        #expect(r.playback.deactivations == 1)
    }

    @Test("a sentence the model fails on is skipped; the rest of the reply still plays")
    internal func failureSkipsOneSentence() {
        let r = rig()
        r.service.speak("One. Two.")
        r.neural.fireFail(0)
        #expect(r.service.isSpeaking)
        r.neural.fireStart(1)
        #expect(r.service.currentSentence == "Two.")
        r.neural.fireFinish(1)
        #expect(!r.service.isActive)
        #expect(r.playback.deactivations == 1)
    }

    @Test("stop silences the neural queue and releases the route exactly once, despite the engine's finished events")
    internal func stopSilencesOnce() {
        let r = rig()
        r.service.speak("One. Two. Three.")
        #expect(r.neural.inFlight.count == 3)
        r.service.stop()
        #expect(r.neural.stops == 1)
        #expect(r.neural.inFlight.isEmpty)
        #expect(!r.service.isActive)
        #expect(r.playback.deactivations == 1)
        r.service.stop()
        #expect(r.neural.stops == 1, "nothing left to stop")
        #expect(r.playback.deactivations == 1)
    }

    @Test("switching voices mid-speech stops what was rendered for the other one")
    internal func switchingStopsPlayback() {
        let r = rig()
        r.service.speak("Neural sentence.")
        #expect(r.neural.spoken.count == 1)
        r.service.usesNeuralVoice = false
        #expect(r.neural.stops == 1)
        #expect(!r.service.isActive)
        r.service.speak("System sentence.")
        #expect(r.synth.spoken.map(\.speechString) == ["System sentence."])
        #expect(r.neural.spoken.count == 1)

        r.service.usesNeuralVoice = true
        #expect(r.synth.stops >= 1)
        #expect(!r.service.isActive)
        #expect(r.neural.prepares == 1, "already ready: no reload")
    }

    @Test("a stale event for an utterance the service no longer tracks is ignored")
    internal func staleEventIgnored() {
        let r = rig()
        r.service.speak("Only.")
        r.neural.fireFinish(0)
        #expect(!r.service.isActive)
        r.service.speak("Next.")
        r.neural.onEvent?(.finished(r.neural.spoken[0].id))
        #expect(r.service.isActive, "the old id must not settle the new speech")
        #expect(r.playback.deactivations == 1)
    }
}
