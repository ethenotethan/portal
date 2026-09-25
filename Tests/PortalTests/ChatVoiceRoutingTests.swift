import Foundation
import Testing
@testable import Portal

/// A stand-in for `LocalVoiceService` so the view-model routing can be tested
/// without a microphone, a model, or the shared singleton.
@MainActor
private final class FakeLocalVoice: LocalVoiceControlling {
    var conversationVisual: ConversationVisual = .claude
    var isEnabledAndAvailable = false
    var conversationMode = false
    var isRunning = false
    var onFinalTranscript: ((String) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var startCount = 0
    var startCalled: Bool { startCount > 0 }
    var stopCalled = false
    var cancelCalled = false

    func start() async {
        startCount += 1
        isRunning = true
    }
    func stop() async {
        stopCalled = true
        isRunning = false
    }
    func cancel() async {
        cancelCalled = true
        isRunning = false
    }
}

/// Stand-in for `TTSService` so the barge-in gate and conversation-phase
/// derivation can be driven without the real synthesizer.
@MainActor
private final class FakeSpeechStatus: ConversationSpeechStatus {
    var isSpeaking = false
}

@Suite("Chat voice routing")
@MainActor
internal struct ChatVoiceRoutingTests {

    @Test("the mic keeps using the gateway when local voice is off")
    internal func gatewayPathWhenLocalDisabled() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = false
        vm.localVoiceService = fake

        let tookOver = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(!tookOver)
        #expect(!fake.startCalled)
        #expect(!vm.isVoiceRecording)
    }

    @Test("the mic transcribes locally when the user opted in")
    internal func localPathWhenEnabled() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        vm.localVoiceService = fake

        let tookOver = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(tookOver)
        #expect(fake.startCalled)
        #expect(vm.isVoiceRecording)
        #expect(fake.onFinalTranscript != nil)
    }

    @Test("a local transcript is submitted as the prompt")
    internal func localTranscriptSubmitted() async {
        let vm = ChatViewModel()
        await vm.submitLocalVoiceTranscript("hello there")
        // With no gateway wired, submitPrompt returns before clearing input, so
        // the text having reached inputText proves the transcript was routed.
        #expect(vm.inputText == "hello there")
        #expect(!vm.isVoiceRecording)
    }

    @Test("an empty local transcript is dropped")
    internal func emptyLocalTranscriptDropped() async {
        let vm = ChatViewModel()
        await vm.submitLocalVoiceTranscript("   ")
        #expect(vm.inputText.isEmpty)
        #expect(!vm.isVoiceRecording)
    }

    @Test("stopping voice recording stops a running local session")
    internal func stopStopsLocalSession() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isRunning = true
        vm.localVoiceService = fake

        await vm.stopVoiceRecording()
        #expect(fake.stopCalled)
        #expect(!vm.isVoiceRecording)
    }

    @Test("startVoiceRecording hands off to the local engine when enabled")
    internal func startVoiceRecordingRoutesToLocal() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        vm.localVoiceService = fake

        await vm.startVoiceRecording()
        #expect(fake.startCalled)
        #expect(vm.isVoiceRecording)
    }

    @Test("live partial transcripts mirror into the composer while recording")
    internal func partialTranscriptMirrorsIntoComposer() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        vm.localVoiceService = fake
        vm.inputText = "stale text"

        _ = await vm.startLocalVoiceRecordingIfEnabled()
        // Starting a capture clears whatever was in the composer.
        #expect(vm.inputText.isEmpty)

        fake.onPartialTranscript?("what is")
        await settle { vm.inputText == "what is" }
        fake.onPartialTranscript?("what is the plan")
        await settle { vm.inputText == "what is the plan" }
        #expect(vm.inputText == "what is the plan")
    }

    @Test("starting the mic begins a conversation only when the mode is on")
    internal func conversationBeginsOnlyWhenModeEnabled() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = false
        vm.localVoiceService = fake

        _ = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(!vm.isConversationActive)

        fake.conversationMode = true
        _ = await vm.startLocalVoiceRecordingIfEnabled()
        // Still recording from the first call, so this returns early; drive a
        // fresh view model to see the mode take effect.
        let vm2 = ChatViewModel()
        let fake2 = FakeLocalVoice()
        fake2.isEnabledAndAvailable = true
        fake2.conversationMode = true
        vm2.localVoiceService = fake2
        _ = await vm2.startLocalVoiceRecordingIfEnabled()
        #expect(vm2.isConversationActive)
    }

    @Test("double-tap starts a conversation even when the setting is off")
    internal func doubleTapForcesConversation() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = false
        vm.localVoiceService = fake

        await vm.startVoiceConversation()
        #expect(vm.isConversationActive)
        #expect(fake.startCount == 1)
        #expect(vm.isVoiceRecording)
    }

    @Test("double-tap upgrades an in-flight one-shot capture to a conversation")
    internal func doubleTapUpgradesOneShot() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = false
        vm.localVoiceService = fake

        // A single-tap one-shot is already running.
        _ = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(!vm.isConversationActive)

        await vm.startVoiceConversation()
        #expect(fake.cancelCalled)          // the one-shot was abandoned
        #expect(vm.isConversationActive)    // and replaced by a conversation
    }

    @Test("the mic stays open across turns in a conversation")
    internal func continuousCaptureKeepsMicOpen() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = true
        vm.localVoiceService = fake

        _ = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(fake.startCount == 1)
        #expect(vm.isConversationActive)
        #expect(fake.isRunning)

        // A reply completes. Capture is continuous — the mic never closed, so
        // it is not (and must not be) reopened for the next turn.
        vm.handleConversationResponseComplete()
        #expect(fake.startCount == 1)
        #expect(fake.isRunning)
    }

    @Test("talking over a reply cancels the in-flight turn")
    internal func bargeInCancelsInFlightTurn() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        vm.localVoiceService = fake

        await vm.startVoiceConversation()
        #expect(vm.isConversationActive)

        // A reply is streaming when the user starts talking again. The partial
        // triggers a barge-in: interrupt() ends the in-flight turn (with no
        // gateway wired it just flips streaming off), and the live words still
        // mirror into the composer as the next prompt.
        vm.isStreaming = true
        fake.onPartialTranscript?("actually wait")
        await settle { !vm.isStreaming }
        #expect(!vm.isStreaming)
        #expect(vm.inputText == "actually wait")

        // Later partials of the same interruption keep mirroring (the barge-in
        // latch only suppresses a *repeated* cancel, not the composer update).
        fake.onPartialTranscript?("actually wait no")
        await settle { vm.inputText == "actually wait no" }
        #expect(vm.inputText == "actually wait no")
    }

    @Test("mic levels drive the voice-reactive orb and reset when it ends")
    internal func voiceLevelTracksMicAndResets() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        vm.localVoiceService = fake

        await vm.startVoiceConversation()
        #expect(vm.voiceLevel == 0)

        // A level arrives → the smoothed orb level rises (but is damped by the
        // moving average, so it lands below the raw value).
        fake.onAudioLevel?(0.8)
        await settle { vm.voiceLevel > 0 }
        #expect(vm.voiceLevel > 0)
        #expect(vm.voiceLevel < 0.8)

        // Ending the conversation returns the orb to rest.
        await vm.endConversation()
        #expect(vm.voiceLevel == 0)
    }

    @Test("conversation phase tracks speaking over thinking over listening")
    internal func conversationPhaseDerivation() async {
        let vm = ChatViewModel()
        let speech = FakeSpeechStatus()
        vm.speechStatus = speech

        // Idle mic → listening.
        vm.isStreaming = false
        speech.isSpeaking = false
        #expect(vm.conversationPhase == .listening)

        // Reply streaming in → thinking.
        vm.isStreaming = true
        #expect(vm.conversationPhase == .thinking)

        // Playback wins over streaming (isSpeaking is set only after the stream
        // ends, but the guard order must not regress).
        speech.isSpeaking = true
        #expect(vm.conversationPhase == .speaking)
    }

    @Test("conversation presentation follows phase, transcript, reply, and selected look")
    internal func conversationPresentation() {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        let speech = FakeSpeechStatus()
        fake.conversationVisual = .openai
        vm.localVoiceService = fake
        vm.speechStatus = speech

        vm.inputText = "  live question  "
        #expect(vm.conversationCaption == "live question")
        #expect(vm.conversationVisual == .openai)

        vm.messages = [ChatMessage(role: .assistant, content: "  spoken reply  ")]
        vm.isStreaming = true
        #expect(vm.conversationCaption == "spoken reply")

        speech.isSpeaking = true
        #expect(vm.conversationCaption == "spoken reply")
    }

    @Test("tapping the mic ends a conversation without submitting")
    internal func tappingEndsConversationWithoutSubmitting() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = true
        vm.localVoiceService = fake

        _ = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(vm.isConversationActive)

        await vm.stopVoiceRecording()
        #expect(fake.cancelCalled)
        #expect(!fake.stopCalled)
        #expect(!vm.isConversationActive)
        #expect(!vm.isVoiceRecording)
    }

    @Test("speaking does not barge in when no reply is in flight")
    internal func partialDoesNotBargeInWhenIdle() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        vm.localVoiceService = fake
        let speech = FakeSpeechStatus()
        vm.speechStatus = speech

        await vm.startVoiceConversation()
        speech.isSpeaking = false
        vm.isStreaming = false

        // Nothing is streaming or being read aloud, so a partial is just the
        // user's next prompt forming — it must not cancel anything.
        fake.onPartialTranscript?("just listening")
        await settle { vm.inputText == "just listening" }
        #expect(vm.inputText == "just listening")
        #expect(!vm.isStreaming)
        #expect(fake.isRunning)
    }

    /// Spin the runloop until `predicate` holds — the partial handler mirrors
    /// text and fires barge-in via a detached `Task`, so effects settle
    /// asynchronously.
    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
    }
}
