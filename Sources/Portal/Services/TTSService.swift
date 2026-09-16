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
internal final class TTSService: ObservableObject, ConversationSpeechStatus {
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

    // MARK: Playback state

    @Published internal var isSpeaking = false
    @Published internal private(set) var isPaused = false
    /// The message whose sentences are queued or playing, so its bubble can
    /// show a speaking indicator and offer Stop instead of Speak.
    @Published internal private(set) var speakingMessageID: UUID?
    /// The sentence the synthesizer is on — what the now-playing bar shows.
    @Published internal private(set) var currentSentence: String?

    internal var isActive: Bool { isSpeaking || isPaused }

    // MARK: Internals

    private let synthesizer: any SpeechSynthesizing
    private let playback: any SpeechPlaybackSessioning
    private let defaults: UserDefaults
    private let delegateBridge = TTSDelegate()

    private var chunker = SentenceChunker()
    /// The message currently being fed deltas.
    private var streamingMessageID: UUID?
    /// Messages that were (at least partly) voiced while streaming, so the
    /// `message.complete` hook flushes their tail instead of re-reading them.
    private var streamedMessageIDs: Set<UUID> = []
    /// Utterances handed to the synthesizer and not yet finished, with what
    /// they say and for which message.
    private var inFlight: [ObjectIdentifier: (messageID: UUID?, sentence: String)] = [:]
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
    }

    /// `playback` defaults to the system session; resolved inside the body
    /// because a `@MainActor` type can't be built in a default-argument
    /// expression (those are evaluated nonisolated).
    internal init(
        synthesizer: any SpeechSynthesizing = AVSpeechSynthesizer(),
        playback: (any SpeechPlaybackSessioning)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.synthesizer = synthesizer
        self.playback = playback ?? SystemSpeechPlaybackSession()
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Keys.enabled)
        speaksWhileStreaming = defaults.object(forKey: Keys.streaming) as? Bool ?? true
        announcesCodeBlocks = defaults.object(forKey: Keys.announceCode) as? Bool ?? true
        rateMultiplier = defaults.object(forKey: Keys.rate) as? Double ?? 1.0
        voiceIdentifier = defaults.string(forKey: Keys.voice)
        delegateBridge.service = self
        synthesizer.delegate = delegateBridge
        self.playback.onRemoteCommand = { [weak self] command in self?.handleRemote(command) }
        log.info("TTS voice: \(self.resolvedVoice?.name ?? "system default")")
    }

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
        for sentence in chunker.push(text) {
            streamedMessageIDs.insert(messageID)
            streamBatch.append(sentence)
            if streamBatch.joined(separator: " ").count >= streamingBatchLength {
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
    }

    // MARK: - Transport

    internal func pause() {
        guard isSpeaking, !isPaused else { return }
        if synthesizer.pauseSpeaking(at: .word) {
            isPaused = true
            publishNowPlaying()
        }
    }

    internal func resume() {
        guard isPaused else { return }
        if synthesizer.continueSpeaking() {
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
        for piece in pieces {
            let spoken = SpokenText.prepare(piece, options: options)
            guard !spoken.isEmpty else { continue }
            let utterance = AVSpeechUtterance(string: spoken)
            utterance.voice = resolvedVoice
            utterance.rate = Float(rateMultiplier) * AVSpeechUtteranceDefaultSpeechRate
            utterance.pitchMultiplier = 1.0
            utterance.volume = 1.0
            // Consecutive utterances are one continuous reading, not a list:
            // no synthesizer-inserted silence between them.
            utterance.preUtteranceDelay = 0
            utterance.postUtteranceDelay = 0
            inFlight[ObjectIdentifier(utterance)] = (messageID, spoken)
            if !isSpeaking {
                playback.activate()
                isSpeaking = true
                isPaused = false
                speakingMessageID = messageID
            }
            synthesizer.speak(utterance)
        }
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

    // MARK: - Delegate callbacks (main actor)

    fileprivate func utteranceDidStart(id: ObjectIdentifier) {
        guard let entry = inFlight[id] else { return }
        isSpeaking = true
        isPaused = false
        speakingMessageID = entry.messageID
        currentSentence = entry.sentence
        publishNowPlaying()
    }

    fileprivate func utteranceDidEnd(id: ObjectIdentifier) {
        inFlight.removeValue(forKey: id)
        if inFlight.isEmpty {
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
