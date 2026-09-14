import AVFoundation
import Foundation
import Testing
@testable import Portal

/// A synthesizer that records what it was asked to say and lets a test play
/// the delegate callbacks back in whatever order it likes.
private final class RecordingSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    var isSpeaking = false
    var isPaused = false
    weak var delegate: (any AVSpeechSynthesizerDelegate)?
    var spoken: [AVSpeechUtterance] = []
    var stops = 0
    var pauseResult = true
    var continueResult = true

    /// The real class the delegate methods are typed against; never actually speaks.
    private let host = AVSpeechSynthesizer()

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
        if pauseResult { isPaused = true }
        return pauseResult
    }

    func continueSpeaking() -> Bool {
        if continueResult { isPaused = false }
        return continueResult
    }

    // Playback of the delegate, as the real synthesizer would drive it.
    func fireStart(_ index: Int) { delegate?.speechSynthesizer?(host, didStart: spoken[index]) }
    func fireFinish(_ index: Int) { delegate?.speechSynthesizer?(host, didFinish: spoken[index]) }
    func firePause() { delegate?.speechSynthesizer?(host, didPause: spoken[0]) }
    func fireContinue() { delegate?.speechSynthesizer?(host, didContinue: spoken[0]) }
}

@MainActor
@Suite("TTS service")
internal struct TTSServiceTests {

    private struct Rig {
        let synth: RecordingSynthesizer
        let playback: RecordingSpeechPlaybackSession
        let service: TTSService
        let defaults: UserDefaults
    }

    private func rig(enabled: Bool = true, streaming: Bool = true) -> Rig {
        let suite = "tts-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let synth = RecordingSynthesizer()
        let playback = RecordingSpeechPlaybackSession()
        let service = TTSService(synthesizer: synth, playback: playback, defaults: defaults)
        service.isEnabled = enabled
        service.speaksWhileStreaming = streaming
        // Per-sentence utterances make the queue observable one step at a time;
        // batching has its own test below.
        service.streamingBatchLength = 0
        service.utteranceTargetLength = 0
        return Rig(synth: synth, playback: playback, service: service, defaults: defaults)
    }

    private func message(_ content: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, content: content, isStreaming: false)
    }

    /// Delegate hops go through `Task { @MainActor }`; let them land.
    private func settle() async {
        for _ in 0..<3 { await Task.yield() }
    }

    // MARK: Settings

    @Test("settings persist to the given defaults and reload")
    internal func settingsPersist() {
        let r = rig()
        r.service.rateMultiplier = 1.5
        r.service.announcesCodeBlocks = false
        r.service.voiceIdentifier = "com.example.voice"
        r.service.speaksWhileStreaming = false

        let reloaded = TTSService(synthesizer: RecordingSynthesizer(), playback: RecordingSpeechPlaybackSession(), defaults: r.defaults)
        #expect(reloaded.isEnabled)
        #expect(reloaded.rateMultiplier == 1.5)
        #expect(!reloaded.announcesCodeBlocks)
        #expect(reloaded.voiceIdentifier == "com.example.voice")
        #expect(!reloaded.speaksWhileStreaming)
    }

    @Test("fresh defaults: speech off, streaming and code announcements on, rate 1.0")
    internal func freshDefaults() {
        let suite = "tts-fresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let service = TTSService(synthesizer: RecordingSynthesizer(), playback: RecordingSpeechPlaybackSession(), defaults: defaults)
        #expect(!service.isEnabled)
        #expect(service.speaksWhileStreaming)
        #expect(service.announcesCodeBlocks)
        #expect(service.rateMultiplier == 1.0)
        #expect(service.voiceIdentifier == nil)
    }

    @Test("toggle flips automatic speech and silences the queue when turning off")
    internal func toggleStops() {
        let r = rig()
        r.service.speak("One sentence. Another one.")
        #expect(r.synth.spoken.count == 2)
        r.service.toggle()
        #expect(!r.service.isEnabled)
        #expect(r.synth.stops >= 1)
        #expect(!r.service.isSpeaking)
    }

    // MARK: Whole texts

    @Test("a whole text is queued a sentence at a time, cleaned, with the configured voice settings")
    internal func speaksInSentences() {
        let r = rig()
        r.service.rateMultiplier = 2.0
        r.service.speak("First **bold** sentence. See `code` here! ```\nx\n```")
        let texts = r.synth.spoken.map(\.speechString)
        #expect(texts == ["First bold sentence.", "See code here!", "Code block omitted."])
        #expect(r.synth.spoken.allSatisfy { $0.rate == Float(2.0) * AVSpeechUtteranceDefaultSpeechRate })
        #expect(r.synth.spoken.allSatisfy { $0.preUtteranceDelay == 0 && $0.postUtteranceDelay == 0 })
        #expect(r.service.isSpeaking)
        #expect(r.playback.activations == 1)
    }

    @Test("speak() is a no-op while automatic speech is off; speakMessage() is not")
    internal func manualIgnoresToggle() {
        let r = rig(enabled: false)
        r.service.speak("Ignored.")
        #expect(r.synth.spoken.isEmpty)

        let msg = message("Read me anyway.")
        r.service.speakMessage(msg)
        #expect(r.synth.spoken.map(\.speechString) == ["Read me anyway."])
        #expect(r.service.speakingMessageID == msg.id)
    }

    @Test("asking for the message already playing stops it instead of restarting")
    internal func speakMessageToggles() {
        let r = rig()
        let msg = message("Hello there.")
        r.service.speakMessage(msg)
        #expect(r.service.isActive)
        r.service.speakMessage(msg)
        #expect(!r.service.isActive)
        #expect(r.service.speakingMessageID == nil)
        #expect(r.synth.stops == 1)
    }

    @Test("the code-block setting decides whether a fence is announced or skipped")
    internal func codeBlockSetting() {
        let r = rig()
        r.service.announcesCodeBlocks = false
        r.service.speak("Before.\n```\nx = 1\n```\nAfter.")
        #expect(r.synth.spoken.map(\.speechString) == ["Before.", "After."])
    }

    // MARK: Streaming

    @Test("deltas are spoken as sentences close, and completion speaks only the tail")
    internal func streamingSpeaksEarlyAndFinishesOnce() {
        let r = rig()
        let id = UUID()
        r.service.streamDelta("The answer ", messageID: id)
        #expect(r.synth.spoken.isEmpty)
        r.service.streamDelta("is 42. Because", messageID: id)
        #expect(r.synth.spoken.map(\.speechString) == ["The answer is 42."])
        #expect(r.service.speakingMessageID == id)
        r.service.streamDelta(" it is", messageID: id)

        // message.complete: the transcript now holds the full text.
        r.service.speakLastAssistantMessage([message("The answer is 42. Because it is", id: id)])
        #expect(r.synth.spoken.map(\.speechString) == ["The answer is 42.", "Because it is"])
        #expect(r.synth.stops == 0, "a streamed message must not be stopped and re-read on completion")
    }

    @Test("a message that was not streamed aloud is read in full on completion")
    internal func completionReadsUnstreamed() {
        let r = rig(streaming: false)
        let id = UUID()
        r.service.streamDelta("Whole. Thing. ", messageID: id)
        #expect(r.synth.spoken.isEmpty)
        r.service.speakLastAssistantMessage([message("Whole. Thing.", id: id)])
        #expect(r.synth.spoken.map(\.speechString) == ["Whole.", "Thing."])
    }

    @Test("a new turn's deltas drop the previous turn's unfinished sentence")
    internal func newTurnResetsChunker() {
        let r = rig()
        r.service.streamDelta("Left hanging", messageID: UUID())
        let second = UUID()
        r.service.streamDelta("New turn. ", messageID: second)
        #expect(r.synth.spoken.map(\.speechString) == ["New turn."])
        r.service.finishStreaming(messageID: second)
        #expect(r.synth.spoken.count == 1)
    }

    @Test("streaming does nothing while automatic speech is off")
    internal func streamingHonoursToggle() {
        let r = rig(enabled: false)
        r.service.streamDelta("Silent. ", messageID: UUID())
        #expect(r.synth.spoken.isEmpty)
        #expect(!r.service.isSpeaking)
    }

    // MARK: Transport and delegate

    @Test("delegate callbacks drive the current sentence, pause state, Now Playing, and settle when the queue drains")
    internal func delegateLifecycle() async {
        let r = rig()
        let msg = message("One. Two.")
        r.service.speakMessage(msg)
        #expect(r.synth.spoken.count == 2)

        r.synth.fireStart(0)
        await settle()
        #expect(r.service.currentSentence == "One.")
        #expect(r.service.speakingMessageID == msg.id)
        #expect(r.playback.nowPlaying.last?.detail == "One.")
        #expect(r.playback.nowPlaying.last?.isPlaying == true)

        r.service.pause()
        #expect(r.service.isPaused)
        r.synth.firePause()
        await settle()
        #expect(r.playback.nowPlaying.last?.isPlaying == false)
        #expect(r.playback.nowPlaying.last?.title == "Paused")

        r.service.resume()
        r.synth.fireContinue()
        await settle()
        #expect(!r.service.isPaused)

        r.synth.fireFinish(0)
        await settle()
        #expect(r.service.isSpeaking, "second sentence still queued")
        r.synth.fireStart(1)
        r.synth.fireFinish(1)
        await settle()
        #expect(!r.service.isSpeaking)
        #expect(r.service.currentSentence == nil)
        #expect(r.service.speakingMessageID == nil)
        #expect(r.playback.deactivations == 1)
    }

    @Test("pause is refused when nothing plays or the synthesizer declines")
    internal func pauseGuards() {
        let r = rig()
        r.service.pause()
        #expect(!r.service.isPaused)
        r.service.speak("Talking.")
        r.synth.pauseResult = false
        r.service.pause()
        #expect(!r.service.isPaused)
        r.synth.pauseResult = true
        r.service.togglePause()
        #expect(r.service.isPaused)
        r.service.togglePause()
        #expect(!r.service.isPaused)
    }

    @Test("remote commands from the lock screen map onto the transport")
    internal func remoteCommands() {
        let r = rig()
        r.service.speak("Talking.")
        r.playback.onRemoteCommand?(.pause)
        #expect(r.service.isPaused)
        r.playback.onRemoteCommand?(.play)
        #expect(!r.service.isPaused)
        r.playback.onRemoteCommand?(.togglePlayPause)
        #expect(r.service.isPaused)
        r.playback.onRemoteCommand?(.stop)
        #expect(!r.service.isActive)
        #expect(r.playback.deactivations == 1)
    }

    @Test("stop releases the audio route exactly once and clears the stream")
    internal func stopReleasesRoute() {
        let r = rig()
        r.service.streamDelta("Half a sent", messageID: UUID())
        r.service.speak("Said.")
        r.service.stop()
        r.service.stop()
        #expect(r.playback.deactivations == 1)
        #expect(!r.service.isActive)
    }

    // MARK: Voices

    @Test("default voice prefers the locale's region, then its language, then anything — best quality within each")
    internal func defaultVoicePreference() {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        guard !voices.isEmpty else { return }
        let us = Locale(identifier: "en_US")
        let chosen = TTSService.defaultVoice(among: voices, locale: us)
        let regional = voices.filter { $0.language.lowercased() == "en-us" }
        if !regional.isEmpty {
            #expect(chosen?.language.lowercased() == "en-us")
            #expect(chosen?.quality.rawValue == regional.map(\.quality.rawValue).max())
        } else {
            #expect(chosen != nil)
        }
        // A region with no voices falls back to the language, not to nothing.
        let fallback = TTSService.defaultVoice(among: voices, locale: Locale(identifier: "en_ZZ"))
        #expect(fallback?.language.lowercased().hasPrefix("en") == true || voices.allSatisfy { !$0.language.hasPrefix("en") })
        #expect(TTSService.defaultVoice(among: voices, locale: Locale(identifier: "zz_ZZ")) != nil)
        #expect(TTSService.defaultVoice(among: [], locale: us) == nil)
    }

    @Test("streamed sentences are batched to the configured length, and the tail flushes at completion")
    internal func streamingBatches() {
        let r = rig()
        r.service.streamingBatchLength = 25
        let id = UUID()
        r.service.streamDelta("One two. ", messageID: id)
        #expect(r.synth.spoken.isEmpty, "8 chars: not enough for an utterance yet")
        r.service.streamDelta("Three four five six. ", messageID: id)
        #expect(r.synth.spoken.map(\.speechString) == ["One two. Three four five six."])
        r.service.streamDelta("Tail", messageID: id)
        r.service.finishStreaming(messageID: id)
        #expect(r.synth.spoken.map(\.speechString) == ["One two. Three four five six.", "Tail"])
    }

    @Test("a whole message is cut at paragraphs, then merged toward the target length without splitting sentences")
    internal func utteranceCutting() {
        let text = "Alpha one. Beta two. Gamma three.\n\nDelta four.\n\n" + String(repeating: "x", count: 50) + "."
        let pieces = TTSService.utterances(from: text, targetLength: 22)
        #expect(pieces == ["Alpha one. Beta two.", "Gamma three.", "Delta four.", String(repeating: "x", count: 50) + "."])
        #expect(TTSService.utterances(from: "A. B. C.", targetLength: 400) == ["A. B. C."])
        #expect(TTSService.utterances(from: "\n\n  \n", targetLength: 10).isEmpty)
    }

    @Test("a voice identifier that isn't installed falls back rather than muting")
    internal func unknownVoiceFallsBack() {
        let r = rig()
        r.service.voiceIdentifier = "com.nowhere.voice.missing"
        r.service.speak("Still audible.")
        #expect(r.synth.spoken.count == 1)
        #expect(r.service.resolvedVoice == TTSService.defaultVoice(among: TTSService.availableVoices(), locale: Locale.current))
    }
}
