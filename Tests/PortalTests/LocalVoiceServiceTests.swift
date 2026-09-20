import AVFoundation
import Foundation
import Testing
@testable import Portal

/// A transcriber that records what it was asked to do and lets a test fire the
/// partial / end-of-utterance callbacks by hand — no CoreML, no model download.
private final class FakeTranscriber: LocalSpeechTranscribing, @unchecked Sendable {
    var loadCalls = 0
    var resetCalls = 0
    var finishText = ""
    var finishError: Error?
    private var partial: (@Sendable (String) -> Void)?
    private var eou: (@Sendable () -> Void)?

    func loadModels() async throws { loadCalls += 1 }
    func onPartial(_ handler: @escaping @Sendable (String) -> Void) async { partial = handler }
    func onEndOfUtterance(_ handler: @escaping @Sendable () -> Void) async { eou = handler }
    func append(_ buffer: AVAudioPCMBuffer) async {}
    func finish() async throws -> String {
        if let finishError { throw finishError }
        return finishText
    }
    func reset() async { resetCalls += 1 }

    func emitPartial(_ text: String) { partial?(text) }
    func triggerEndOfUtterance() { eou?() }
}

@MainActor
private final class FakeMicrophone: MicrophoneCapturing {
    var started = false
    var stopped = false
    var startError: Error?
    var onAudioLevel: (@Sendable (Float) -> Void)?
    var onRouteInterruption: (@Sendable () -> Void)?

    func start(feeding transcriber: any LocalSpeechTranscribing) throws {
        if let startError { throw startError }
        started = true
    }
    func stop() { stopped = true }

    /// Fire the level sink the service wired up, as the real mic tap would.
    func emitLevel(_ value: Float) { onAudioLevel?(value) }

    /// Simulate the engine re-arming after an audio-route change.
    func emitRouteInterruption() { onRouteInterruption?() }
}

private struct MicFailure: Error {}

@Suite("Local voice service")
@MainActor
internal struct LocalVoiceServiceTests {

    /// Spin the runloop until `predicate` holds — the partial/EOU callbacks hop
    /// back to the main actor through a `Task`, so state settles asynchronously.
    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<1_000 where !predicate() { await Task.yield() }
    }

    private func makeService(
        enabled: Bool = true,
        permission: Bool = true
    ) -> (LocalVoiceService, FakeTranscriber, FakeMicrophone) {
        let transcriber = FakeTranscriber()
        let mic = FakeMicrophone()
        let service = LocalVoiceService(
            transcriber: transcriber,
            microphone: mic,
            requestPermission: { permission }
        )
        service.isEnabled = enabled
        return (service, transcriber, mic)
    }

    @Test("a build with no engine linked reports itself unavailable")
    internal func defaultInitIsUnavailableWithoutEngine() {
        // In the SwiftPM test build FluidAudio isn't linked, so the default
        // factories hand back nil and the mic button stays on the gateway path.
        let service = LocalVoiceService()
        #expect(!service.isAvailable)
        #expect(!service.isEnabledAndAvailable)
    }

    @Test("permission is denied when no engine is linked")
    internal func defaultPermissionDeniedWithoutEngine() async {
        #expect(await LocalVoiceService.defaultPermission() == false)
    }

    @Test("start is a no-op until the user opts in")
    internal func startNoOpWhenDisabled() async {
        let (service, transcriber, mic) = makeService(enabled: false)
        await service.start()
        #expect(!service.isRunning)
        #expect(!mic.started)
        #expect(transcriber.loadCalls == 0)
    }

    @Test("start is a no-op when microphone permission is denied")
    internal func startNoOpWhenPermissionDenied() async {
        let (service, _, mic) = makeService(permission: false)
        await service.start()
        #expect(!service.isRunning)
        #expect(!mic.started)
    }

    @Test("start loads the model once and begins capture")
    internal func startBeginsCapture() async {
        let (service, transcriber, mic) = makeService()
        await service.start()
        #expect(service.isRunning)
        #expect(mic.started)
        #expect(transcriber.loadCalls == 1)

        // A second start (after a stop) reuses the loaded model.
        transcriber.finishText = ""
        await service.stop()
        await service.start()
        #expect(transcriber.loadCalls == 1)
    }

    @Test("a failed microphone start leaves the service idle")
    internal func startFailureLeavesIdle() async {
        let (service, _, mic) = makeService()
        mic.startError = MicFailure()
        await service.start()
        #expect(!service.isRunning)
    }

    @Test("end-of-utterance emits the final transcript and stops")
    internal func endOfUtteranceEmitsTranscript() async {
        let (service, transcriber, mic) = makeService()
        var final: String?
        service.onFinalTranscript = { final = $0 }
        await service.start()

        transcriber.finishText = "hello world"
        transcriber.triggerEndOfUtterance()
        await settle { final != nil }

        #expect(final == "hello world")
        #expect(!service.isRunning)
        #expect(mic.stopped)
    }

    @Test("a conversation keeps the mic open after end-of-utterance")
    internal func conversationEmitsButKeepsListening() async {
        let (service, transcriber, mic) = makeService()
        var finals: [String] = []
        service.onFinalTranscript = { finals.append($0) }
        await service.startConversation()

        // First utterance ends: the transcript is emitted, but capture stays
        // live for the next turn — the mic is not stopped.
        transcriber.finishText = "first turn"
        transcriber.triggerEndOfUtterance()
        await settle { finals.count == 1 }
        #expect(finals == ["first turn"])
        #expect(service.isRunning)
        #expect(!mic.stopped)

        // A second utterance flows through the same open mic — no re-`start`.
        transcriber.finishText = "second turn"
        transcriber.triggerEndOfUtterance()
        await settle { finals.count == 2 }
        #expect(finals == ["first turn", "second turn"])
        #expect(service.isRunning)
        #expect(!mic.stopped)

        // Ending the conversation is what finally tears capture down.
        await service.cancel()
        #expect(!service.isRunning)
        #expect(mic.stopped)
    }

    @Test("mic levels surface for the voice-reactive orb and reset on cancel")
    internal func audioLevelFlowsThroughAndResets() async {
        let (service, _, mic) = makeService()
        var levels: [Float] = []
        service.onAudioLevel = { levels.append($0) }
        await service.startConversation()

        mic.emitLevel(0.4)
        mic.emitLevel(0.9)
        await settle { levels.count == 2 }
        #expect(levels == [0.4, 0.9])
        #expect(service.inputLevel == 0.9)

        // Ending capture returns the level to silence so the orb settles.
        await service.cancel()
        #expect(service.inputLevel == 0)
    }

    @Test("an audio-route change surfaces a brief notice, cleared when capture ends")
    internal func routeChangeSurfacesNoticeAndClears() async {
        let (service, _, mic) = makeService()
        await service.startConversation()
        #expect(service.routeNotice == nil)

        // The engine re-armed the mic after the route flipped (a Bluetooth
        // speaker connecting): the service should reassure, not go silent.
        mic.emitRouteInterruption()
        await settle { service.routeNotice != nil }
        #expect(service.routeNotice == "Audio device changed — still listening.")

        // Ending the conversation clears the notice along with capture.
        await service.cancel()
        #expect(service.routeNotice == nil)
    }

    @Test("a manual stop also emits the transcript")
    internal func stopEmitsTranscript() async {
        let (service, transcriber, mic) = makeService()
        var final: String?
        service.onFinalTranscript = { final = $0 }
        await service.start()

        transcriber.finishText = "stop now"
        await service.stop()

        #expect(final == "stop now")
        #expect(!service.isRunning)
        #expect(mic.stopped)
    }

    @Test("an empty transcript is dropped, not submitted")
    internal func emptyTranscriptDropped() async {
        let (service, transcriber, _) = makeService()
        var fired = false
        service.onFinalTranscript = { _ in fired = true }
        await service.start()

        transcriber.finishText = "   \n  "
        await service.stop()

        #expect(!fired)
        #expect(!service.isRunning)
    }

    @Test("a failed flush falls back to the last partial transcript")
    internal func finishFailureFallsBackToPartial() async {
        let (service, transcriber, _) = makeService()
        var final: String?
        service.onFinalTranscript = { final = $0 }
        await service.start()

        transcriber.emitPartial("partial fallback")
        await settle { service.partialTranscript == "partial fallback" }
        transcriber.finishError = MicFailure()
        await service.stop()

        #expect(final == "partial fallback")
        #expect(!service.isRunning)
    }

    @Test("partial transcripts are forwarded to the onPartialTranscript hook")
    internal func partialTranscriptCallbackFires() async {
        let (service, transcriber, _) = makeService()
        var latest: String?
        service.onPartialTranscript = { latest = $0 }
        await service.start()

        transcriber.emitPartial("live words")
        await settle { latest == "live words" }
        #expect(latest == "live words")
    }

    @Test("stop when idle does nothing")
    internal func stopWhenIdleIsNoOp() async {
        let (service, _, mic) = makeService()
        await service.stop()
        #expect(!mic.stopped)
    }

    @Test("partial transcripts surface for live display")
    internal func partialTranscriptUpdates() async {
        let (service, transcriber, _) = makeService()
        await service.start()
        transcriber.emitPartial("partial text")
        await settle { service.partialTranscript == "partial text" }
        #expect(service.partialTranscript == "partial text")
    }

    @Test("cancel tears down capture without emitting a transcript")
    internal func cancelDropsTranscript() async {
        let (service, transcriber, mic) = makeService()
        var fired = false
        service.onFinalTranscript = { _ in fired = true }
        await service.start()

        transcriber.finishText = "should not be sent"
        await service.cancel()

        #expect(!fired)
        #expect(!service.isRunning)
        #expect(mic.stopped)
    }

    @Test("cancel when idle does nothing")
    internal func cancelWhenIdleIsNoOp() async {
        let (service, _, mic) = makeService()
        await service.cancel()
        #expect(!mic.stopped)
    }

    @Test("conversation mode persists across instances")
    internal func conversationModePersists() {
        UserDefaults.standard.removeObject(forKey: LocalVoiceService.conversationKey)
        let first = LocalVoiceService(transcriber: FakeTranscriber(), microphone: FakeMicrophone())
        #expect(!first.conversationMode)
        first.conversationMode = true

        let second = LocalVoiceService(transcriber: FakeTranscriber(), microphone: FakeMicrophone())
        #expect(second.conversationMode)
        UserDefaults.standard.removeObject(forKey: LocalVoiceService.conversationKey)
    }

    @Test("conversation looks expose stable labels and persist across instances")
    internal func conversationVisualPersists() {
        let key = LocalVoiceService.conversationVisualKey
        UserDefaults.standard.removeObject(forKey: key)

        #expect(ConversationVisual.claude.id == "claude")
        #expect(ConversationVisual.claude.label == "Claude — organic orb")
        #expect(ConversationVisual.openai.id == "openai")
        #expect(ConversationVisual.openai.label == "OpenAI — gradient sphere")

        let first = LocalVoiceService(transcriber: FakeTranscriber(), microphone: FakeMicrophone())
        #expect(first.conversationVisual == .claude)
        first.conversationVisual = .openai

        let second = LocalVoiceService(transcriber: FakeTranscriber(), microphone: FakeMicrophone())
        #expect(second.conversationVisual == .openai)

        UserDefaults.standard.set("unknown", forKey: key)
        let invalid = LocalVoiceService(transcriber: FakeTranscriber(), microphone: FakeMicrophone())
        #expect(invalid.conversationVisual == .claude)
        UserDefaults.standard.removeObject(forKey: key)
    }

    @Test("the opt-in persists across instances")
    internal func enabledPersists() {
        UserDefaults.standard.removeObject(forKey: LocalVoiceService.enabledKey)
        let transcriber = FakeTranscriber()
        let mic = FakeMicrophone()
        let first = LocalVoiceService(transcriber: transcriber, microphone: mic)
        #expect(!first.isEnabled)
        first.isEnabled = true

        let second = LocalVoiceService(transcriber: FakeTranscriber(), microphone: FakeMicrophone())
        #expect(second.isEnabled)
        UserDefaults.standard.removeObject(forKey: LocalVoiceService.enabledKey)
    }
}
