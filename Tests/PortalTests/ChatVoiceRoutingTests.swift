import Foundation
import Testing
@testable import Portal

/// A stand-in for `LocalVoiceService` so the view-model routing can be tested
/// without a microphone, a model, or the shared singleton.
@MainActor
private final class FakeLocalVoice: LocalVoiceControlling {
    var isEnabledAndAvailable = false
    var isRunning = false
    var onFinalTranscript: ((String) -> Void)?
    var startCalled = false
    var stopCalled = false

    func start() async {
        startCalled = true
        isRunning = true
    }
    func stop() async {
        stopCalled = true
        isRunning = false
    }
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
}
