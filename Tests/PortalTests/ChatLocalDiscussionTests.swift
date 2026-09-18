import Foundation
import Testing
@testable import Portal

/// A stand-in for `LocalVoiceService`, so the hands-free half of a discussion can
/// be driven without a microphone or a model.
@MainActor
private final class FakeVoice: LocalVoiceControlling {
    var conversationVisual: ConversationVisual = .claude
    var isEnabledAndAvailable = true
    var conversationMode = false
    var isRunning = false
    var onFinalTranscript: ((String) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    var cancelCalled = false

    func start() async { isRunning = true }
    func stop() async { isRunning = false }
    func cancel() async {
        cancelCalled = true
        isRunning = false
    }
}

/// A stand-in for `LocalChatService`: replays deltas, records prompts, and can
/// hang mid-reply the way a real generation does when it gets interrupted.
@MainActor
private final class FakeLocalChat: LocalChatControlling {
    var isAvailable = true
    var isEnabled = true
    var isPreparing = false
    var lastError: String?
    var deltas: [String] = ["Because ", "the session isn't Sendable."]
    /// When set, `respond` never finishes on its own — it waits to be cancelled.
    var hangs = false
    var prepareCount = 0
    private(set) var instructions: [String] = []
    private(set) var prompts: [String] = []
    private(set) var endSessionCount = 0

    func prepare() { prepareCount += 1 }

    func respond(
        instructions: String,
        to prompt: String,
        onDelta: @escaping (String) -> Void
    ) async -> Result<String, Error> {
        self.instructions.append(instructions)
        prompts.append(prompt)
        for delta in deltas { onDelta(delta) }
        if hangs {
            while !Task.isCancelled { await Task.yield() }
            return .failure(CancellationError())
        }
        return .success(deltas.joined())
    }

    func endSession() async { endSessionCount += 1 }
}

/// A recorder for the synthesizer, so what gets spoken is observable.
@MainActor
private final class FakeSpeaker: ConversationSpeaking {
    var isSpeaking = false
    var isEnabled = false
    var speaksWhileStreaming = true
    private(set) var spoken: [String] = []
    private(set) var spokenWhole: [String] = []
    private(set) var finishedIDs: [UUID] = []
    private(set) var stopCount = 0

    func speak(_ text: String) { spokenWhole.append(text) }
    func streamDelta(_ text: String, messageID: UUID) { spoken.append(text) }
    func finishStreaming(messageID: UUID) { finishedIDs.append(messageID) }
    func stop() { stopCount += 1 }
}

@Suite("Chat local discussion")
@MainActor
internal struct ChatLocalDiscussionTests {

    /// A view model with all three collaborators faked, plus one assistant reply
    /// to talk about.
    private func makeViewModel() -> (ChatViewModel, FakeLocalChat, FakeVoice, FakeSpeaker) {
        let vm = ChatViewModel()
        let chat = FakeLocalChat()
        let voice = FakeVoice()
        let speaker = FakeSpeaker()
        vm.localChatService = chat
        vm.localVoiceService = voice
        vm.speechStatus = speaker
        vm.conversationSpeaker = speaker
        return (vm, chat, voice, speaker)
    }

    private func anchor(_ text: String = "Reply with A, B, or C.") -> ChatMessage {
        ChatMessage(role: .assistant, content: text)
    }

    @Test("nothing opens until the user has opted in")
    internal func requiresOptIn() async {
        let (vm, chat, _, _) = makeViewModel()
        chat.isEnabled = false

        await vm.startLocalDiscussion(about: anchor())
        #expect(vm.localDiscussion == nil)
        #expect(chat.prepareCount == 0)
    }

    @Test("an empty reply is not worth discussing")
    internal func ignoresEmptyAnchor() async {
        let (vm, _, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor("   "))
        #expect(vm.localDiscussion == nil)
    }

    @Test("opening a discussion anchors it, loads the model, and opens the mic")
    internal func opensAnchoredOnTheMessage() async {
        let (vm, chat, voice, speaker) = makeViewModel()
        let message = anchor("""
        Two ways to go:

        A. Keep the session in an actor
        B. Rebuild it per call
        """)

        await vm.startLocalDiscussion(about: message)
        #expect(vm.localDiscussion?.id == message.id)
        #expect(vm.localDiscussion?.options == ["Keep the session in an actor", "Rebuild it per call"])
        // The (potentially multi-gigabyte) load starts before the first question.
        #expect(chat.prepareCount == 1)
        // Spoken, hands-free, and audible.
        #expect(vm.isConversationActive)
        #expect(voice.isRunning)
        #expect(speaker.isEnabled)
    }

    @Test("without on-device voice the discussion still opens, for typing")
    internal func opensWithoutVoice() async {
        let (vm, _, voice, _) = makeViewModel()
        voice.isEnabledAndAvailable = false

        await vm.startLocalDiscussion(about: anchor())
        #expect(vm.localDiscussion != nil)
        #expect(!vm.isConversationActive)
        #expect(!voice.isRunning)
    }

    @Test("spoken input goes to the local model, not the gateway")
    internal func transcriptRoutesLocally() async {
        let (vm, chat, _, speaker) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())

        await vm.submitLocalVoiceTranscript("why the actor?")

        #expect(chat.prompts == ["why the actor?"])
        // Nothing reached the session: no message, no gateway turn.
        #expect(vm.messages.isEmpty)
        #expect(!vm.isStreaming)
        // The exchange is the local model's, and it was read aloud.
        #expect(vm.localDiscussion?.turns.count == 2)
        #expect(vm.localDiscussion?.turns.first?.role == .user)
        #expect(vm.localDiscussion?.turns.last?.text == "Because the session isn't Sendable.")
        #expect(speaker.spoken == ["Because ", "the session isn't Sendable."])
        #expect(speaker.finishedIDs.count == 1)
        #expect(!vm.isLocalStreaming)
        // The composer is cleared — the caption carries the exchange now.
        #expect(vm.inputText.isEmpty)
    }

    @Test("with sentence-by-sentence speech off, the reply is spoken whole")
    internal func speaksWholeReplyWhenNotStreaming() async {
        let (vm, _, _, speaker) = makeViewModel()
        speaker.speaksWhileStreaming = false
        await vm.startLocalDiscussion(about: anchor())

        await vm.submitLocalDiscussionInput("why?")
        // Streaming deltas into a synthesizer that ignores them would leave the
        // discussion silent, which for a spoken feature is a bug.
        #expect(speaker.spoken.isEmpty)
        #expect(speaker.spokenWhole == ["Because the session isn't Sendable."])
    }

    @Test("the anchor and its options ground every question in the exchange")
    internal func questionsAreGrounded() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor("Use an actor for the session."))

        await vm.submitLocalDiscussionInput("why?")
        await vm.submitLocalDiscussionInput("and the cache?")

        #expect(chat.prompts == ["why?", "and the cache?"])
        #expect(chat.instructions.count == 2)
        #expect(chat.instructions.allSatisfy { $0.contains("Use an actor for the session.") })
        // Identical instructions are what let the engine keep one chat session
        // (and its KV cache) alive across turns.
        #expect(chat.instructions[0] == chat.instructions[1])
        #expect(vm.localDiscussion?.turns.count == 4)
    }

    @Test("typed input is dropped when no discussion is open")
    internal func typedInputNeedsADiscussion() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.submitLocalDiscussionInput("why?")
        #expect(chat.prompts.isEmpty)
    }

    @Test("with no discussion open the mic still goes to the gateway")
    internal func transcriptStillRoutesToGatewayWhenClosed() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.submitLocalVoiceTranscript("hello there")
        // With no gateway wired, submitPrompt returns before clearing the input,
        // so the text sitting in the composer proves it took the gateway path.
        #expect(vm.inputText == "hello there")
        #expect(chat.prompts.isEmpty)
    }

    @Test("talking over a local reply cancels it and leaves the gateway alone")
    internal func bargeInCancelsLocalReply() async {
        let (vm, chat, voice, speaker) = makeViewModel()
        chat.hangs = true
        chat.deltas = ["Because "]
        await vm.startLocalDiscussion(about: anchor())

        let asking = Task { await vm.submitLocalDiscussionInput("why the actor?") }
        await settle { vm.isLocalStreaming }
        #expect(vm.conversationPhase == .thinking)

        voice.onPartialTranscript?("actually wait")
        await settle { !vm.isLocalStreaming }
        _ = await asking.value

        #expect(!vm.isLocalStreaming)
        #expect(speaker.stopCount >= 1)
        // The gateway turn was never involved, and what the model had already said
        // is kept rather than blanked.
        #expect(!vm.isStreaming)
        #expect(vm.localDiscussion?.turns.last?.text == "Because ")
        #expect(vm.localDiscussion?.turns.last?.isStreaming == false)
        #expect(vm.inputText == "actually wait")
    }

    @Test("the phase and caption follow the local reply while it streams")
    internal func phaseAndCaptionFollowLocalReply() async {
        let (vm, chat, _, _) = makeViewModel()
        chat.hangs = true
        chat.deltas = ["Because the session "]
        await vm.startLocalDiscussion(about: anchor())

        let asking = Task { await vm.submitLocalDiscussionInput("why?") }
        await settle { !vm.conversationCaption.isEmpty }
        // The caption is the LOCAL model's words, not the last thing the agent said.
        #expect(vm.isLocalStreaming)
        #expect(vm.conversationPhase == .thinking)
        #expect(vm.conversationCaption == "Because the session")

        await vm.endLocalDiscussion()
        _ = await asking.value
        #expect(vm.conversationPhase == .listening)
    }

    @Test("ending the discussion closes the session and the mic")
    internal func endingClosesEverything() async {
        let (vm, chat, voice, speaker) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why?")

        await vm.endLocalDiscussion()
        #expect(vm.localDiscussion == nil)
        #expect(chat.endSessionCount == 1)
        #expect(!vm.isConversationActive)
        #expect(voice.cancelCalled)
        #expect(speaker.stopCount >= 1)
    }

    @Test("tapping the mic to end a conversation closes the discussion with it")
    internal func endingTheConversationClosesTheDiscussion() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())

        await vm.stopVoiceRecording()
        // A discussion left open with no mic and no card would be unreachable.
        #expect(vm.localDiscussion == nil)
        #expect(chat.endSessionCount == 1)
    }

    @Test("re-opening on the same message resumes, a different one starts fresh")
    internal func reopeningResumesOrResets() async {
        let (vm, chat, _, _) = makeViewModel()
        let first = anchor("First reply.")
        await vm.startLocalDiscussion(about: first)
        await vm.submitLocalDiscussionInput("why?")
        #expect(vm.localDiscussion?.turns.count == 2)

        // Same message: the exchange so far survives.
        await vm.startLocalDiscussion(about: first)
        #expect(vm.localDiscussion?.id == first.id)
        #expect(vm.localDiscussion?.turns.count == 2)
        #expect(chat.endSessionCount == 0)

        // A different reply is a different conversation.
        let second = anchor("Second reply.")
        await vm.startLocalDiscussion(about: second)
        #expect(vm.localDiscussion?.id == second.id)
        #expect(vm.localDiscussion?.turns.isEmpty == true)
        #expect(chat.endSessionCount == 1)
    }

    @Test("handing over needs something to hand over")
    internal func handoffNeedsAnExchange() async {
        let (vm, _, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())

        await vm.handLocalDiscussionToAgent()
        // Nothing was said yet, so the discussion is untouched.
        #expect(vm.localDiscussion != nil)
        #expect(vm.inputText.isEmpty)
    }

    @Test("handing over sends the exchange to the agent and closes the discussion")
    internal func handoffSubmitsTheExchange() async {
        let (vm, chat, voice, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")

        await vm.handLocalDiscussionToAgent()
        // The mic stays open: the agent's answer is spoken and the next question
        // needs no tap.
        #expect(vm.isConversationActive)
        #expect(!voice.cancelCalled)
        // With no gateway wired the prompt stays in the composer, which is what
        // proves the handoff text is what gets submitted.
        #expect(vm.inputText.contains("Me: why the actor?"))
        #expect(vm.inputText.contains("Local model: Because the session isn't Sendable."))
        #expect(vm.localDiscussion == nil)
        #expect(chat.endSessionCount == 1)
    }

    /// Spin the runloop until `predicate` holds — local replies stream from a
    /// child task, so effects settle asynchronously.
    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<10_000 where !predicate() { await Task.yield() }
    }
}
