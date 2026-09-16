import Foundation
import Testing
@testable import Portal

/// A stand-in for `LocalVoiceService` so the view-model routing can be tested
/// without a microphone, a model, or the shared singleton.
@MainActor
private final class FakeLocalVoice: LocalVoiceControlling {
    var isEnabledAndAvailable = false
    var conversationMode = false
    var isRunning = false
    var onFinalTranscript: ((String) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
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

/// Stand-in for `TTSService` so the relisten gate can be driven without the
/// real synthesizer.
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

    @Test("a completed reply reopens the mic once speech is quiet")
    internal func replyReopensMicWhenQuiet() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = true
        let speech = FakeSpeechStatus()
        vm.localVoiceService = fake
        vm.speechStatus = speech

        _ = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(fake.startCount == 1)

        // Reply finishes but the agent is still speaking → mic stays closed.
        speech.isSpeaking = true
        vm.handleConversationResponseComplete()
        #expect(fake.startCount == 1)

        // Speech ends → the mic reopens for the next turn.
        speech.isSpeaking = false
        vm.relistenIfQuiet()
        await settle { fake.startCount == 2 }
        #expect(fake.startCount == 2)
    }

    @Test("a completed reply reopens the mic when speech never starts")
    internal func replyReopensMicViaFallbackWhenSpeechNeverStarts() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = true
        let speech = FakeSpeechStatus()
        vm.localVoiceService = fake
        vm.speechStatus = speech

        _ = await vm.startLocalVoiceRecordingIfEnabled()
        #expect(fake.startCount == 1)

        // The reply completes but TTS never reports speaking (e.g. the
        // `isSpeaking` flag never flips, the race that stranded turn two). The
        // mic must still reopen on its own — via the quiet-speech observer or
        // the no-speech fallback timer — with no explicit relisten call.
        speech.isSpeaking = false
        vm.handleConversationResponseComplete()
        await settleSlowly { fake.startCount == 2 }
        #expect(fake.startCount == 2)
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

    @Test("relisten is ignored when no conversation turn is pending")
    internal func relistenIgnoredWithoutPendingTurn() async {
        let vm = ChatViewModel()
        let fake = FakeLocalVoice()
        fake.isEnabledAndAvailable = true
        fake.conversationMode = true
        vm.localVoiceService = fake

        _ = await vm.startLocalVoiceRecordingIfEnabled()
        let before = fake.startCount
        // No reply completed, so a stray speech-ended signal must not reopen it.
        vm.relistenIfQuiet()
        #expect(fake.startCount == before)
    }

    /// Spin the runloop until `predicate` holds — relisten reopens the mic via a
    /// detached `Task`, so the call count settles asynchronously.
    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
    }

    /// Poll with real delays — the relisten fallback fires on a ~1.2s timer, so
    /// yielding alone never advances the wall clock enough to see it.
    private func settleSlowly(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<40 where !predicate() {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
