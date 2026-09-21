import AVFoundation
import Combine
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "TTSService")

/// The slice of `AVSpeechSynthesizer` the service uses, as a protocol so a
/// test can stand in a recorder. `AVSpeechSynthesizer` conforms as-is: every
/// requirement is spelled exactly like the method it already has.
internal protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    func speak(_ utterance: AVSpeechUtterance)
    @discardableResult func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func pauseSpeaking(at boundary: AVSpeechBoundary) -> Bool
    @discardableResult func continueSpeaking() -> Bool
}

extension AVSpeechSynthesizer: SpeechSynthesizing {}

/// Read-only view of whether a spoken reply is currently playing. The chat view
/// model uses it to hold off reopening the hands-free conversation mic until the
/// agent has finished talking — the on-device recognizer has no echo
/// cancellation, so an open mic would transcribe the TTS audio itself. A
/// protocol so the view model can be tested without the real synthesizer.
@MainActor
internal protocol ConversationSpeechStatus: AnyObject {
    var isSpeaking: Bool { get }
}

/// The playback surface a spoken side-conversation drives: `ConversationSpeechStatus`
/// plus the ability to actually say something.
///
/// Separate from `ConversationSpeechStatus` because the two roles are genuinely
/// different — the gateway conversation only *observes* playback (the agent's
/// replies are spoken by the `message.complete` path), while a local discussion
/// owns its replies end to end and has to stream them out itself. Kept as a
/// protocol for the same reason: `ChatViewModel` can be tested against a recorder.
@MainActor
internal protocol ConversationSpeaking: ConversationSpeechStatus {
    /// Automatic speech. Settable because opening a spoken discussion has to turn
    /// it on — an unspoken spoken conversation is nothing at all.
    var isEnabled: Bool { get set }
    /// Whether streamed deltas get voiced as they arrive. Read rather than
    /// forced: a caller that streams has to know, because with this off
    /// `streamDelta` is a no-op and the reply has to be spoken whole instead.
    var speaksWhileStreaming: Bool { get }
    func speak(_ text: String)
    func streamDelta(_ text: String, messageID: UUID)
    func finishStreaming(messageID: UUID)
    func stop()
}

/// On-device text-to-speech using Apple's AVSpeechSynthesizer.
/// Speaks assistant responses aloud — no network, no API key, no privacy concerns.
///
/// Speech is queued **a sentence at a time**. While a turn streams, each
/// sentence is spoken as soon as it closes (`SentenceChunker`), so the voice
/// starts on the first clause instead of after the whole answer has landed;
/// a response spoken on demand is chunked the same way so the
/// `currentSentence` indicator and pause/resume behave identically. Every
/// sentence passes through `SpokenText.prepare` first, so code fences, URLs
/// and markdown syntax are never read aloud.
///
/// Three independent settings, all persisted: `isEnabled` (speak responses
/// automatically), `speaksWhileStreaming` (start before the turn ends), and
/// the voice/rate/code-block preferences that shape every utterance.
@MainActor
internal final class TTSService: ObservableObject, ConversationSpeaking {
    static let shared = TTSService()

    // MARK: Settings

    /// Speak each finished assistant response automatically.
    @Published internal var isEnabled = false {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled) }
    }
    /// With `isEnabled`, begin speaking sentences while the turn is still
    /// streaming rather than after `message.complete`.
    @Published internal var speaksWhileStreaming = true {
        didSet { defaults.set(speaksWhileStreaming, forKey: Keys.streaming) }
    }
    /// Say "Code block omitted." where a fence was, instead of skipping it
    /// silently — the difference between "then run" and "then run this."
    @Published internal var announcesCodeBlocks = true {
        didSet { defaults.set(announcesCodeBlocks, forKey: Keys.announceCode) }
    }
    /// Speaking rate as a multiple of the system default (`0.5 ... 2.0`).
    @Published internal var rateMultiplier: Double = 1.0 {
        didSet { defaults.set(rateMultiplier, forKey: Keys.rate) }
    }
    /// `AVSpeechSynthesisVoice.identifier`; nil picks the best voice for the
    /// current locale at speak time (so a newly downloaded voice is used
    /// without a setting having to change).
    @Published internal var voiceIdentifier: String? {
        didSet { defaults.set(voiceIdentifier, forKey: Keys.voice) }
    }
    /// Which neural voice speaks, by the model's voice id (see the engine's
    /// `availableVoices`). Only consulted when the neural voice is on. Changing
    /// it stops what's queued — that audio was rendered in the other voice.
    @Published internal var neuralVoice: String {
        didSet {
            defaults.set(neuralVoice, forKey: Keys.neuralVoiceID)
            guard neuralVoice != oldValue else { return }
            neural?.voice = neuralVoice
            if isActive { stop() }
        }
    }
    /// Persona "warmth", `-1 ... 1`: negative is brighter, positive deeper. Maps
    /// to a pitch shift on the neural voice (system voices ignore it). Takes
    /// effect on the next sentence, so a nudge mid-reply isn't jarring.
    @Published internal var warmth: Double = 0 {
        didSet {
            defaults.set(warmth, forKey: Keys.warmth)
            neural?.pitch = Self.pitchCents(forWarmth: warmth)
        }
    }
    /// Speak with the on-device neural voice instead of the system one. Off by
    /// default: it is a download, and the system voice needs none. Turning it
    /// on starts the load right away, so the wait is spent watching a label in
    /// Settings rather than mid-conversation. Until the model is ready — or if
    /// it never is — speech falls back to the system voice rather than going
    /// silent. No default value: with one, the wrapper would already exist
    /// when `init` assigns the persisted choice and this `didSet` would run
    /// then too, loading the model twice.
    @Published internal var usesNeuralVoice: Bool {
        didSet {
            defaults.set(usesNeuralVoice, forKey: Keys.neuralVoice)
            guard usesNeuralVoice != oldValue else { return }
            // Whatever is queued was rendered for the other voice.
            stop()
            if usesNeuralVoice { neural?.prepare() }
        }
    }
    /// Where the neural voice is in its load, mirrored from the engine so
    /// Settings can observe it.
    @Published internal private(set) var neuralState: NeuralSpeechState = .idle

    // MARK: Playback state

    @Published internal var isSpeaking = false
    @Published internal private(set) var isPaused = false
    /// Live 0...1 loudness of the neural voice as it plays, smoothed, so the
    /// conversation orb can breathe with the assistant's own speech. Zero when
    /// silent or when the system voice (which reports no samples) is speaking.
    @Published internal private(set) var outputLevel: Float = 0
    /// The message whose sentences are queued or playing, so its bubble can
    /// show a speaking indicator and offer Stop instead of Speak.
    @Published internal private(set) var speakingMessageID: UUID?
    /// The sentence the synthesizer is on — what the now-playing bar shows.
    @Published internal private(set) var currentSentence: String?

    internal var isActive: Bool { isSpeaking || isPaused }

    // MARK: Internals

    private let synthesizer: any SpeechSynthesizing
    /// The neural voice, when this build links one. nil in the SwiftPM test
    /// build and on hardware that can't run it; the setting then has nothing
    /// to switch to and the toggle is not offered.
    private let neural: (any NeuralSpeechSynthesizing)?
    private let playback: any SpeechPlaybackSessioning
    private let defaults: UserDefaults
    private let delegateBridge = TTSDelegate()

    private var chunker = SentenceChunker()
    /// The message currently being fed deltas.
    private var streamingMessageID: UUID?
    /// Messages that were (at least partly) voiced while streaming, so the
    /// `message.complete` hook flushes their tail instead of re-reading them.
    private var streamedMessageIDs: Set<UUID> = []
    /// One queued utterance, whichever engine holds it. The system synthesizer
    /// only ever hands back the `AVSpeechUtterance` object, so its identity is
    /// the key there; the neural engine is given, and reports, a UUID.
    private enum UtteranceKey: Hashable {
        case system(ObjectIdentifier)
        case neural(UUID)
    }
    /// Utterances handed to an engine and not yet finished, with what they
    /// say and for which message.
    private var inFlight: [UtteranceKey: (messageID: UUID?, sentence: String)] = [:]
    /// Streamed sentences waiting to be spoken as one utterance. A synthesizer
    /// shapes intonation per utterance, so one-sentence utterances with a gap
    /// between each sound like a list being read; a few sentences at a time
    /// sounds like a paragraph.
    private var streamBatch: [String] = []
    /// How much streamed text to gather before speaking it, in characters.
    /// Lower starts sooner and sounds choppier. Tests set 0 for per-sentence.
    internal var streamingBatchLength = 160
    /// Longest utterance a whole message is cut into; a paragraph shorter than
    /// this is spoken in one breath.
    internal var utteranceTargetLength = 360

    private enum Keys {
        static let enabled = "portal.tts.enabled"
        static let streaming = "portal.tts.speaksWhileStreaming"
        static let announceCode = "portal.tts.announcesCodeBlocks"
        static let rate = "portal.tts.rateMultiplier"
        static let voice = "portal.tts.voiceIdentifier"
        static let neuralVoice = "portal.tts.neuralVoice"
        static let neuralVoiceID = "portal.tts.neuralVoiceID"
        static let warmth = "portal.tts.warmth"
    }

    /// Production wiring: the system synthesizer, the system playback session,
    /// and the neural engine this build links (if any). A convenience so the
    /// main-actor engine is built in a main-actor context — a default argument
    /// is evaluated nonisolated and couldn't.
    internal convenience init() {
        self.init(synthesizer: AVSpeechSynthesizer(), neural: TTSService.defaultNeuralEngine())
    }

    /// Tests inject recorders here. `playback` defaults to the system session,
    /// resolved inside the body for the same reason as above.
    internal init(
        synthesizer: any SpeechSynthesizing,
        playback: (any SpeechPlaybackSessioning)? = nil,
        defaults: UserDefaults = .standard,
        neural: (any NeuralSpeechSynthesizing)? = nil
    ) {
        self.synthesizer = synthesizer
        self.neural = neural
        self.playback = playback ?? SystemSpeechPlaybackSession()
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        speaksWhileStreaming = defaults.object(forKey: Keys.streaming) as? Bool ?? true
        announcesCodeBlocks = defaults.object(forKey: Keys.announceCode) as? Bool ?? true
        rateMultiplier = defaults.object(forKey: Keys.rate) as? Double ?? 1.0
        voiceIdentifier = defaults.string(forKey: Keys.voice)
        usesNeuralVoice = defaults.bool(forKey: Keys.neuralVoice)
        // "alba" is the model's own default voice; a stored choice overrides it.
        neuralVoice = defaults.string(forKey: Keys.neuralVoiceID) ?? "alba"
        warmth = defaults.object(forKey: Keys.warmth) as? Double ?? 0
        delegateBridge.service = self
        synthesizer.delegate = delegateBridge
        self.playback.onRemoteCommand = { [weak self] command in self?.handleRemote(command) }
        if let neural {
            neuralState = neural.state
            neural.onStateChange = { [weak self] state in self?.neuralState = state }
            neural.onEvent = { [weak self] event in self?.handleNeuralEvent(event) }
            neural.onOutputLevel = { [weak self] level in self?.updateOutputLevel(level) }
            // Property observers don't fire for values assigned in init, so push
            // the restored persona (voice + warmth) into the engine by hand.
            neural.voice = neuralVoice
            neural.pitch = Self.pitchCents(forWarmth: warmth)
            // `didSet` doesn't run for the stored value, so a neural voice chosen
            // last session starts loading here.
            if usesNeuralVoice { neural.prepare() }
        }
        log.info("TTS voice: \(self.resolvedVoice?.name ?? "system default"), neural voice \(neural == nil ? "unavailable" : (self.usesNeuralVoice ? "on" : "off"))")
    }

    // MARK: - Engines

    /// Whether this build and machine have a neural voice to offer at all.
    internal var isNeuralVoiceAvailable: Bool { neural != nil }

    /// The neural voices offered in the picker; empty when no engine is linked.
    internal var neuralVoices: [NeuralVoiceOption] { neural?.availableVoices ?? [] }

    /// Map the `-1 ... 1` warmth control to a pitch shift in cents: positive
    /// warmth deepens the voice. ±250 cents (≈2½ semitones) is a clear persona
    /// shift without tipping into a caricature.
    internal static func pitchCents(forWarmth warmth: Double) -> Float {
        Float(-max(-1, min(1, warmth)) * 250)
    }

    /// Whether the next utterance goes to the neural voice: chosen, linked, and
    /// loaded. Anything short of that is the system voice.
    internal var speaksWithNeuralVoice: Bool { usesNeuralVoice && neural?.state.isReady == true }

    // MARK: - Voices

    /// Every installed voice, best first within each language.
    internal static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language != $1.language { return $0.language < $1.language }
            if $0.quality != $1.quality { return $0.quality.rawValue > $1.quality.rawValue }
            return $0.name < $1.name
        }
    }

    /// The voice utterances will use: the chosen one if it's still installed,
    /// else the best voice for the current locale, else the first voice on
    /// the device.
    internal var resolvedVoice: AVSpeechSynthesisVoice? {
        if let voiceIdentifier, let chosen = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return chosen
        }
        return Self.defaultVoice(among: Self.availableVoices(), locale: Locale.current)
    }

    /// Pure so the preference order is testable. Region first, then quality:
    /// a US locale gets the best `en-US` voice before any `en-AU` one, however
    /// good — an accent the person didn't choose reads as "wrong voice" even
    /// when it's premium. Only with no regional match does the whole language
    /// compete, and only with none of those does any voice at all.
    internal static func defaultVoice(among voices: [AVSpeechSynthesisVoice], locale: Locale) -> AVSpeechSynthesisVoice? {
        let tag = locale.identifier(.bcp47) // "en-US"
        let language = locale.language.languageCode?.identifier ?? String(tag.prefix(2))
        func best(_ pool: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
            pool.max { $0.quality.rawValue < $1.quality.rawValue }
        }
        return best(voices.filter { $0.language.caseInsensitiveCompare(tag) == .orderedSame })
            ?? best(voices.filter { $0.language.lowercased().hasPrefix(language.lowercased()) })
            ?? voices.first
    }

    // MARK: - Toggling

    /// Flip automatic speech. Turning it off silences anything queued.
    internal func toggle() {
        isEnabled.toggle()
        if !isEnabled {
            stop()
        }
        log.info("TTS \(self.isEnabled ? "enabled" : "disabled")")
    }

    // MARK: - Speaking whole texts

    /// Speak a text when automatic speech is on. Stops whatever was playing.
    internal func speak(_ text: String) {
        guard isEnabled else { return }
        stop()
        enqueue(text: text, messageID: nil)
    }

    /// The `message.complete` hook. If the message was already being voiced
    /// sentence-by-sentence while it streamed, only its unfinished tail is
    /// spoken; otherwise the whole response is read now.
    internal func speakLastAssistantMessage(_ messages: [ChatMessage]) {
        guard isEnabled,
              let lastBot = messages.last(where: { $0.role == .assistant && !$0.content.isEmpty }) else { return }
        if streamedMessageIDs.contains(lastBot.id) {
            finishStreaming(messageID: lastBot.id)
            return
        }
        stop()
        enqueue(text: lastBot.contentWithoutAttachments, messageID: lastBot.id)
    }

    /// Read one message on demand, regardless of the automatic setting.
    /// Asking for the message already playing stops it instead.
    internal func speakMessage(_ message: ChatMessage) {
        if speakingMessageID == message.id, isActive {
            stop()
            return
        }
        stop()
        enqueue(text: message.contentWithoutAttachments, messageID: message.id)
    }

    /// A sample of the configured voice, for the settings pane.
    internal func previewVoice() {
        stop()
        enqueue(text: "This is how responses will sound.", messageID: nil)
    }

    // MARK: - Speaking a stream

    /// Feed a delta for `messageID`. Sentences are spoken as they close.
    /// No-op unless automatic speech and streaming speech are both on, so the
    /// chat view model can call this unconditionally.
    internal func streamDelta(_ text: String, messageID: UUID) {
        guard isEnabled, speaksWhileStreaming else { return }
        if streamingMessageID != messageID {
            // A new turn: anything left of the previous one is dropped, not
            // spoken late over the new answer.
            chunker.reset()
            streamingMessageID = messageID
        }
        // Batching exists to hide the system voice's per-utterance intonation
        // reset. The neural voice phrases each sentence naturally and starts in
        // tens of milliseconds, so it gets every sentence the moment it closes.
        let batchLength = speaksWithNeuralVoice ? 0 : streamingBatchLength
        for sentence in chunker.push(text) {
            streamedMessageIDs.insert(messageID)
            streamBatch.append(sentence)
            if streamBatch.joined(separator: " ").count >= batchLength {
                speakStreamBatch(messageID: messageID)
            }
        }
    }

    private func speakStreamBatch(messageID: UUID) {
        guard !streamBatch.isEmpty else { return }
        let joined = streamBatch.joined(separator: " ")
        streamBatch.removeAll()
        enqueue(text: joined, messageID: messageID, chunk: false)
    }

    /// The stream for `messageID` ended: speak whatever sentence was still open.
    internal func finishStreaming(messageID: UUID) {
        guard streamingMessageID == messageID else { return }
        streamingMessageID = nil
        if let tail = chunker.flush() {
            streamedMessageIDs.insert(messageID)
            streamBatch.append(tail)
        }
        speakStreamBatch(messageID: messageID)
        // No more sentences are coming, so release the neural engine's lead: a
        // short reply, or the tail here, plays now rather than waiting for a
        // cushion that will never fill.
        if speaksWithNeuralVoice { neural?.flush() }
        // The stream is closed. If nothing is left playing — the last sentence
        // finished before the stream closed, so `utteranceDidEnd` deliberately
        // held the route open — settle now that no more sentences are coming.
        if inFlight.isEmpty {
            settle()
        }
    }

    // MARK: - Transport

    /// Which engine the current playback belongs to. Utterances all go to one
    /// engine per run (`stop()` sits between any switch), so the first in
    /// flight decides.
    private var playingEngineIsNeural: Bool {
        inFlight.keys.contains { if case .neural = $0 { return true } else { return false } }
    }

    internal func pause() {
        guard isSpeaking, !isPaused else { return }
        let paused = playingEngineIsNeural
            ? neural?.pause() ?? false
            : synthesizer.pauseSpeaking(at: .word)
        if paused {
            isPaused = true
            publishNowPlaying()
        }
    }

    internal func resume() {
        guard isPaused else { return }
        let resumed = playingEngineIsNeural
            ? neural?.resume() ?? false
            : synthesizer.continueSpeaking()
        if resumed {
            isPaused = false
            publishNowPlaying()
        }
    }

    internal func togglePause() {
        if isPaused {
            resume()
        } else {
            pause()
        }
    }

    /// Silence everything: the utterance playing, the ones queued behind it,
    /// and any half-collected sentence from the stream.
    internal func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused || !inFlight.isEmpty {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if playingEngineIsNeural {
            // Clear first: the engine reports each silenced utterance as
            // finished, and those must not be mistaken for a queue draining.
            inFlight.removeAll()
            neural?.stop()
        }
        chunker.reset()
        streamBatch.removeAll()
        streamingMessageID = nil
        inFlight.removeAll()
        settle()
    }

    // MARK: - Queueing

    /// Turn `text` into utterances. `chunk` cuts a whole response at sentence
    /// boundaries into pieces of about `utteranceTargetLength`, never across a
    /// paragraph break — long enough for the voice to phrase naturally, short
    /// enough that pause and the sentence indicator still feel responsive.
    /// A stream hands in pre-batched text and passes `false`.
    private func enqueue(text: String, messageID: UUID?, chunk: Bool = true) {
        let pieces = chunk ? Self.utterances(from: text, targetLength: utteranceTargetLength) : [text]
        let options: SpokenText.Options = announcesCodeBlocks ? .default : .skippingCode
        let useNeural = speaksWithNeuralVoice
        for piece in pieces {
            let spoken = SpokenText.prepare(piece, options: options)
            guard !spoken.isEmpty else { continue }
            if !isSpeaking {
                playback.activate()
                isSpeaking = true
                isPaused = false
                speakingMessageID = messageID
            }
            if useNeural, let neural {
                let id = UUID()
                inFlight[.neural(id)] = (messageID, spoken)
                neural.speak(spoken, id: id, rate: rateMultiplier)
            } else {
                let utterance = AVSpeechUtterance(string: spoken)
                utterance.voice = resolvedVoice
                utterance.rate = Float(rateMultiplier) * AVSpeechUtteranceDefaultSpeechRate
                utterance.pitchMultiplier = 1.0
                utterance.volume = 1.0
                // Consecutive utterances are one continuous reading, not a list:
                // no synthesizer-inserted silence between them.
                utterance.preUtteranceDelay = 0
                utterance.postUtteranceDelay = 0
                inFlight[.system(ObjectIdentifier(utterance))] = (messageID, spoken)
                synthesizer.speak(utterance)
            }
        }
        // A whole reply (not a mid-stream batch) is fully queued now, so let the
        // neural engine release its lead and start speaking. Streamed batches
        // pass `chunk: false` and are flushed by `finishStreaming` instead, so
        // the lead can build across the reply's first sentences.
        if useNeural, chunk { neural?.flush() }
    }

    /// Cut `text` into utterances: split at paragraph breaks, then merge each
    /// paragraph's sentences greedily up to `targetLength`. A single sentence
    /// longer than the target stays whole — cutting mid-sentence is worse.
    internal static func utterances(from text: String, targetLength: Int) -> [String] {
        var out: [String] = []
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        for paragraph in paragraphs {
            var splitter = SentenceChunker()
            var sentences = splitter.push(paragraph)
            if let tail = splitter.flush() { sentences.append(tail) }
            var current = ""
            for sentence in sentences {
                if current.isEmpty {
                    current = sentence
                } else if current.count + 1 + sentence.count <= targetLength {
                    current += " " + sentence
                } else {
                    out.append(current)
                    current = sentence
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out
    }

    // MARK: - Engine callbacks (main actor)

    fileprivate func utteranceDidStart(id: ObjectIdentifier) {
        utteranceDidStart(key: .system(id))
    }

    fileprivate func utteranceDidEnd(id: ObjectIdentifier) {
        utteranceDidEnd(key: .system(id))
    }

    /// Fold each raw output-loudness sample into `outputLevel` with an
    /// exponential moving average, taming the per-buffer jitter so the orb
    /// pulses smoothly with the assistant's voice instead of strobing — the
    /// same shaping `ChatViewModel` applies to the mic level.
    private func updateOutputLevel(_ raw: Float) {
        let clamped = max(0, min(1, raw))
        outputLevel = outputLevel * 0.7 + clamped * 0.3
    }

    private func handleNeuralEvent(_ event: NeuralSpeechEvent) {
        switch event {
        case .started(let id):
            utteranceDidStart(key: .neural(id))
        case .finished(let id):
            utteranceDidEnd(key: .neural(id))
        case .failed(let id, let reason):
            // One sentence lost, not the whole reply: the rest of the queue
            // still plays, and the failure is logged rather than shown.
            log.error("Neural voice failed on an utterance: \(reason)")
            utteranceDidEnd(key: .neural(id))
        }
    }

    private func utteranceDidStart(key: UtteranceKey) {
        guard let entry = inFlight[key] else { return }
        isSpeaking = true
        isPaused = false
        speakingMessageID = entry.messageID
        currentSentence = entry.sentence
        publishNowPlaying()
    }

    private func utteranceDidEnd(key: UtteranceKey) {
        guard inFlight.removeValue(forKey: key) != nil else { return }
        // Don't tear the route down between sentences of a still-streaming
        // reply. The queue empties in the gap between one sentence finishing
        // and the next being closed by the model, but the reply isn't over —
        // deactivating and reactivating the audio route across that gap adds
        // latency of its own and blanks the orb. Stay live until the stream
        // has closed (`finishStreaming` clears `streamingMessageID`) and the
        // queue has truly drained; `finishStreaming` settles the case where
        // the last sentence finished before the stream closed.
        if inFlight.isEmpty, streamingMessageID == nil {
            settle()
        }
    }

    fileprivate func utteranceDidPause() {
        isPaused = true
        publishNowPlaying()
    }

    fileprivate func utteranceDidContinue() {
        isPaused = false
        publishNowPlaying()
    }

    /// Back to idle: flags cleared, Now Playing gone, audio route released.
    private func settle() {
        let wasActive = isSpeaking || isPaused
        isSpeaking = false
        isPaused = false
        speakingMessageID = nil
        currentSentence = nil
        outputLevel = 0
        if wasActive {
            playback.deactivate()
        }
    }

    private func publishNowPlaying() {
        playback.updateNowPlaying(
            title: isPaused ? "Paused" : "Speaking",
            detail: currentSentence,
            isPlaying: isSpeaking && !isPaused
        )
    }

    private func handleRemote(_ command: SpeechRemoteCommand) {
        switch command {
        case .play: resume()
        case .pause: pause()
        case .togglePlayPause: togglePause()
        case .stop: stop()
        }
    }
}

// MARK: - Default engine wiring

extension TTSService {
    #if canImport(FluidAudio)
    /// PocketTTS, on Apple Silicon. On Intel the CoreML graphs would run on
    /// the CPU far slower than real time, which is worse than the system voice.
    internal static func defaultNeuralEngine() -> (any NeuralSpeechSynthesizing)? {
        HardwareProfile.current().isAppleSilicon ? PocketTtsSpeechEngine() : nil
    }
    #else
    /// No neural voice linked in this build.
    internal static func defaultNeuralEngine() -> (any NeuralSpeechSynthesizing)? { nil }
    #endif
}

// MARK: - Delegate

/// `AVSpeechSynthesizerDelegate` callbacks arrive off the main actor; this
/// bridge hops them across to the owning service. Only the utterance's
/// identity crosses the hop — `AVSpeechUtterance` itself isn't `Sendable`, and
/// identity is all the service keys on. The back-reference is set once at init
/// and only ever read, so the class is safe to share with the synthesizer's
/// thread.
private final class TTSDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    fileprivate weak var service: TTSService?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak service] in service?.utteranceDidStart(id: id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak service] in service?.utteranceDidEnd(id: id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak service] in service?.utteranceDidEnd(id: id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        Task { @MainActor [weak service] in service?.utteranceDidPause() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        Task { @MainActor [weak service] in service?.utteranceDidContinue() }
    }
}
