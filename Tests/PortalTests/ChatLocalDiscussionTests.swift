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
    /// When set, `respond` fails instead of answering.
    var failure: Error?
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
        if let failure { return .failure(failure) }
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
        chat.deltas = ["Keep the session in an actor."]

        await vm.handLocalDiscussionToAgent()
        // The conversation is over: the mic closes so the turn goes out as work
        // rather than chat, and nothing overheard can interrupt the agent.
        #expect(!vm.isConversationActive)
        #expect(voice.cancelCalled)
        #expect(vm.refocusInput == 1)
        // With no gateway wired the prompt stays in the composer, which is what
        // proves the handoff text is what gets submitted. The local model's
        // write-up leads it; the exchange follows as the reasoning.
        #expect(vm.inputText.hasPrefix("Keep the session in an actor."))
        #expect(vm.inputText.contains("Me: why the actor?"))
        #expect(vm.inputText.contains("Local model: Because the session isn't Sendable."))
        #expect(vm.localDiscussion == nil)
        #expect(chat.endSessionCount == 1)
        #expect(!vm.isDraftingHandoff)
    }

    @Test("the write-up is a separate pass, and is not spoken or shown as a turn")
    internal func draftingIsSilentAndSeparate() async {
        let (vm, chat, _, speaker) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor("Use an actor."))
        await vm.submitLocalDiscussionInput("why the actor?")
        let spokenAfterDiscussion = speaker.spoken.count

        await vm.handLocalDiscussionToAgent()
        #expect(chat.prompts.count == 2)
        // Its own grounding, not another question in the spoken exchange — so the
        // engine builds a clean session instead of writing in the spoken voice.
        #expect(chat.instructions[1] != chat.instructions[0])
        #expect(chat.instructions[1].contains(LocalDiscussion.noAskSentinel))
        #expect(chat.prompts[1].contains("Me: why the actor?"))
        // Nothing new was read aloud: the next voice is the agent's.
        #expect(speaker.spoken.count == spokenAfterDiscussion)
        #expect(speaker.spokenWhole.isEmpty)
    }

    @Test("a declined write-up still hands over the conversation")
    internal func handoffFallsBackWhenTheWriteUpDeclines() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")
        chat.deltas = [LocalDiscussion.noAskSentinel]

        await vm.handLocalDiscussionToAgent()
        // Worse to read than a drafted ask, but nothing is lost.
        #expect(!vm.inputText.contains(LocalDiscussion.noAskSentinel))
        #expect(vm.inputText.contains("Me: why the actor?"))
        #expect(vm.inputText.contains("Pick this up from here."))
    }

    @Test("a write-up that fails outright still hands over the conversation")
    internal func handoffFallsBackWhenTheWriteUpFails() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")
        chat.failure = LocalChatError.emptyResponse

        await vm.handLocalDiscussionToAgent()
        #expect(vm.inputText.contains("Me: why the actor?"))
        #expect(vm.inputText.contains("Pick this up from here."))
        #expect(!vm.isDraftingHandoff)
    }

    @Test("closing the card mid-write-up abandons it and sends nothing")
    internal func closingDuringTheWriteUpCancelsIt() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")
        chat.hangs = true

        let handing = Task { await vm.handLocalDiscussionToAgent() }
        await settle { vm.isDraftingHandoff }
        #expect(vm.conversationPhase == .thinking)

        await vm.endLocalDiscussion()
        _ = await handing.value
        // The tap wins: no gateway turn, and the surface isn't left claiming to be
        // writing a prompt for a discussion that's gone.
        #expect(!vm.isDraftingHandoff)
        #expect(vm.inputText.isEmpty)
        #expect(vm.localDiscussion == nil)
    }

    @Test("the handoff is a tool-enabled turn, not a chat-mode one")
    internal func handoffIsWork() async {
        let backend = VoiceBackendSpy()
        let (vm, chat, _, _) = makeViewModel()
        vm.setGatewayClient(backend)
        _ = vm.beginSwitchToSession(key: "voice-session")
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")
        chat.deltas = ["Keep the session in an actor."]
        #expect(vm.isConversationActive)

        await vm.handLocalDiscussionToAgent()
        // A conversation-mode turn is routed through the gateway's tool-less path,
        // which would have the agent *answer* the ask instead of carrying it out —
        // the exact "it doesn't go" the handoff exists to fix.
        #expect(backend.submittedChatModes == [false])
        #expect(backend.submittedPrompts.first?.text.hasPrefix("Keep the session in an actor.") == true)
        #expect(backend.submittedPrompts.first?.text.contains("Me: why the actor?") == true)
        #expect(!vm.isConversationActive)
    }

    @Test("nothing overheard during the write-up starts another local reply")
    internal func writeUpIgnoresTheMic() async {
        let (vm, chat, voice, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")
        chat.hangs = true

        let handing = Task { await vm.handLocalDiscussionToAgent() }
        await settle { vm.isDraftingHandoff }
        // The tail of the user's own sentence, or the room. Either would have
        // started a second generation against the same engine while the prompt was
        // being written, and the handoff would lose the race to it.
        voice.onPartialTranscript?("and also the cache")
        await settle { vm.inputText == "and also the cache" }
        #expect(vm.localDiscussionLiveUtterance == nil)
        await vm.submitLocalVoiceTranscript("and also the cache")
        #expect(chat.prompts.count == 2)
        #expect(vm.localDiscussion?.turns.count == 2)
        #expect(vm.inputText.isEmpty)

        await vm.endLocalDiscussion()
        _ = await handing.value
    }

    @Test("talking over a spoken local reply silences it")
    internal func bargeInSilencesTheReply() async {
        let (vm, _, voice, speaker) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")
        // Generation is done; the synthesizer is still reading the reply out.
        speaker.isSpeaking = true
        let stopsBefore = speaker.stopCount

        voice.onPartialTranscript?("okay")
        await settle { speaker.stopCount > stopsBefore }
        // Without this the reply talks over the user's "okay, submit" — there was
        // no generation left to cancel, and cancelling is all barge-in used to do.
        #expect(speaker.stopCount == stopsBefore + 1)
    }

    // MARK: - Watching the thread as it happens

    @Test("what the user is saying shows up in the thread before it's final")
    internal func liveUtteranceJoinsTheThread() async {
        let (vm, _, voice, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())

        voice.onPartialTranscript?("so what about the cache")
        await settle { vm.localDiscussionLiveUtterance != nil }
        // Their own half of the exchange used to exist only in the composer at the
        // bottom of the window, so it was invisible until it had been answered.
        #expect(vm.localDiscussionLiveUtterance == "so what about the cache")

        await vm.submitLocalVoiceTranscript("so what about the cache?")
        // Once it's a turn, it isn't provisional any more.
        #expect(vm.localDiscussionLiveUtterance == nil)
        #expect(vm.localDiscussion?.turns.first?.text == "so what about the cache?")
    }

    @Test("there is no live utterance without a discussion or without speech")
    internal func liveUtteranceNeedsBoth() async {
        let (vm, _, voice, _) = makeViewModel()
        vm.inputText = "typing at the gateway"
        #expect(vm.localDiscussionLiveUtterance == nil)

        await vm.startLocalDiscussion(about: anchor())
        // Opening the mic clears the composer, so there is nothing to show yet.
        #expect(vm.localDiscussionLiveUtterance == nil)
        voice.onPartialTranscript?("   ")
        await settle { vm.inputText == "   " }
        #expect(vm.localDiscussionLiveUtterance == nil)
    }

    @Test("the thread's render key moves with everything the user can see")
    internal func renderKeyTracksTheThread() async {
        let (vm, chat, voice, _) = makeViewModel()
        #expect(vm.localDiscussionRenderKey.isEmpty)

        await vm.startLocalDiscussion(about: anchor())
        let opened = vm.localDiscussionRenderKey
        #expect(!opened.isEmpty)

        // A word added to the live utterance is a visible change, and so is a turn
        // arriving — the chat scrolls on this key, so anything it misses is a line
        // the user has to go hunting for.
        voice.onPartialTranscript?("why")
        await settle { vm.localDiscussionRenderKey != opened }
        let speaking = vm.localDiscussionRenderKey
        #expect(speaking != opened)

        chat.deltas = ["Because ", "the session isn't Sendable."]
        await vm.submitLocalDiscussionInput("why the actor?")
        #expect(vm.localDiscussionRenderKey != speaking)
    }

    // MARK: - Saying you're done

    @Test("saying \"okay, let's submit\" ends the discussion and sends it")
    internal func spokenCloseOutHandsOver() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalVoiceTranscript("why the actor?")
        chat.deltas = ["Keep the session in an actor."]

        await vm.submitLocalVoiceTranscript("okay, let's submit")
        // Finishing a hands-free conversation must not require finding a button.
        #expect(vm.localDiscussion == nil)
        #expect(vm.inputText.hasPrefix("Keep the session in an actor."))
        // The close-out itself is not a question, so it never reached the model as
        // one, and it is not in the handoff either.
        #expect(chat.prompts.count == 2)
        #expect(!vm.inputText.contains("Me: okay, let's submit"))
    }

    @Test("a close-out phrase typed into the card works the same way")
    internal func typedCloseOutHandsOver() async {
        let (vm, _, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")

        await vm.submitLocalDiscussionInput("send it")
        #expect(vm.localDiscussion == nil)
        #expect(vm.inputText.contains("Me: why the actor?"))
    }

    @Test("a question that only sounds like a close-out is still a question")
    internal func questionsAreNotCloseOuts() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())
        await vm.submitLocalDiscussionInput("why the actor?")

        await vm.submitLocalDiscussionInput("go on")
        #expect(vm.localDiscussion?.turns.count == 4)
        #expect(chat.prompts == ["why the actor?", "go on"])
        #expect(vm.inputText.isEmpty)
    }

    @Test("a close-out before anything has been said is just another question")
    internal func closeOutNeedsAnExchange() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion(about: anchor())

        await vm.submitLocalDiscussionInput("go ahead")
        // "go" opens far more conversations than it closes.
        #expect(vm.localDiscussion != nil)
        #expect(chat.prompts == ["go ahead"])
    }

    // MARK: - Picking a discussion back up

    @Test("closing keeps the exchange, and re-opening picks it up")
    internal func closingKeepsTheExchange() async {
        let (vm, chat, _, _) = makeViewModel()
        let message = anchor("Use an actor.")
        await vm.startLocalDiscussion(about: message)
        await vm.submitLocalDiscussionInput("why?")

        await vm.endLocalDiscussion()
        #expect(vm.localDiscussion == nil)

        await vm.startLocalDiscussion(about: message)
        #expect(vm.localDiscussion?.turns.count == 2)
        // The engine's own memory of it is gone, so the exchange is re-stated in
        // the prompt rather than silently forgotten.
        await vm.submitLocalDiscussionInput("and the cache?")
        #expect(chat.instructions.last?.contains("Me: why?") == true)
        #expect(vm.localDiscussion?.turns.count == 4)
    }

    @Test("a discussion handed to the agent is still there to pick up")
    internal func handoffKeepsTheThread() async {
        let (vm, _, _, _) = makeViewModel()
        let message = anchor("Use an actor.")
        await vm.startLocalDiscussion(about: message)
        await vm.submitLocalDiscussionInput("why?")
        await vm.handLocalDiscussionToAgent()

        await vm.startLocalDiscussion(about: message)
        #expect(vm.localDiscussion?.turns.count == 2)
    }

    @Test("starting over is the way to throw an exchange away")
    internal func startingOverClearsTheThread() async {
        let (vm, chat, _, _) = makeViewModel()
        let message = anchor("Use an actor.")
        await vm.startLocalDiscussion(about: message)
        await vm.submitLocalDiscussionInput("why?")

        await vm.restartLocalDiscussion()
        #expect(vm.localDiscussion?.turns.isEmpty == true)
        #expect(vm.localDiscussion?.id == message.id)
        // Same anchor, so the discussion is still about the same reply.
        #expect(vm.localDiscussion?.anchorText == "Use an actor.")
        #expect(chat.endSessionCount == 1)

        // And it does not come back on the next open.
        await vm.endLocalDiscussion()
        await vm.startLocalDiscussion(about: message)
        #expect(vm.localDiscussion?.turns.isEmpty == true)
    }

    // MARK: - Started from the composer

    @Test("the composer can open a discussion with no reply to anchor to")
    internal func opensFromTheComposer() async {
        let (vm, chat, voice, speaker) = makeViewModel()
        vm.recentSessionsProvider = { Self.sessions }

        await vm.startLocalDiscussion()
        // The case the anchored entry point couldn't reach: nothing sent yet.
        #expect(vm.localDiscussion != nil)
        #expect(vm.localDiscussion?.isAnchored == false)
        #expect(chat.prepareCount == 1)
        #expect(vm.isConversationActive)
        #expect(voice.isRunning)
        #expect(speaker.isEnabled)
    }

    @Test("a composer discussion is briefed on the other sessions")
    internal func briefedOnOtherSessions() async {
        let (vm, chat, _, _) = makeViewModel()
        vm.recentSessionsProvider = { Self.sessions }

        await vm.startLocalDiscussion()
        await vm.submitLocalDiscussionInput("what are we working on today?")

        // The whole point: this question used to be unanswerable by construction.
        let instructions = chat.instructions.first ?? ""
        #expect(instructions.contains("Wiki space discovery fix"))
        #expect(instructions.contains("Harness forkdiff CI gate"))
        #expect(instructions.contains("last message: \"pushed as #492\""))
        #expect(vm.localDiscussion?.briefing.entries.count == 2)
    }

    @Test("what's in the composer comes along as the draft")
    internal func carriesTheDraft() async {
        let (vm, chat, _, _) = makeViewModel()
        vm.inputText = "  Here's a design for the cron digest.  "

        await vm.startLocalDiscussion()
        await vm.submitLocalDiscussionInput("is that one change or two?")

        #expect(vm.localDiscussion?.draftText == "Here's a design for the cron digest.")
        #expect(chat.instructions.first?.contains("NOT yet sent to the agent") == true)
        #expect(chat.instructions.first?.contains("Here's a design for the cron digest.") == true)
    }

    @Test("re-tapping resumes, and an anchored discussion is not folded into it")
    internal func composerReopenRules() async {
        let (vm, chat, _, _) = makeViewModel()
        await vm.startLocalDiscussion()
        await vm.submitLocalDiscussionInput("where did we leave the wiki fix?")
        let id = vm.localDiscussion?.id

        // Same discussion: the exchange survives and the KV cache stays warm.
        await vm.startLocalDiscussion()
        #expect(vm.localDiscussion?.id == id)
        #expect(vm.localDiscussion?.turns.count == 2)
        #expect(chat.endSessionCount == 0)

        // A discussion about a reply is about something else; the composer button
        // does not quietly re-point that one...
        await vm.startLocalDiscussion(about: anchor("Use an actor."))
        #expect(vm.localDiscussion?.isAnchored == true)
        #expect(vm.localDiscussion?.turns.isEmpty == true)
        // ...and coming back to the composer returns to the thread it left, rather
        // than to a blank one.
        await vm.startLocalDiscussion()
        #expect(vm.localDiscussion?.id == id)
        #expect(vm.localDiscussion?.turns.count == 2)
        #expect(chat.endSessionCount == 2)
    }

    @Test("a composer discussion started with a new draft does not resume the old one")
    internal func composerDiscussionRestartsOnANewDraft() async {
        let (vm, _, _, _) = makeViewModel()
        vm.inputText = "Rework the cron digest."
        await vm.startLocalDiscussion()
        await vm.submitLocalDiscussionInput("one change or two?")
        await vm.endLocalDiscussion()

        // Different text in the composer is a different ask; answering it against
        // the old draft would be answering about something that isn't there.
        vm.inputText = "Pin the forkdiff base instead."
        await vm.startLocalDiscussion()
        #expect(vm.localDiscussion?.draftText == "Pin the forkdiff base instead.")
        #expect(vm.localDiscussion?.turns.isEmpty == true)
    }

    @Test("a pre-send conclusion is submitted too, so the session continues")
    internal func composerHandoffSubmits() async {
        let (vm, chat, voice, _) = makeViewModel()
        vm.inputText = "Rework the cron digest."
        await vm.startLocalDiscussion()
        await vm.submitLocalDiscussionInput("one change or two?")
        chat.deltas = ["Split the digest change from the node surface."]

        await vm.handLocalDiscussionToAgent()
        // "Let's submit" has to actually continue the session — a prompt parked in
        // the composer waiting for a keystroke is not a conclusion.
        #expect(vm.inputText.hasPrefix("Split the digest change from the node surface."))
        #expect(vm.inputText.contains("Rework the cron digest."))
        #expect(vm.inputText.contains("Me: one change or two?"))
        // The mic closes, exactly as on the anchored path.
        #expect(!vm.isConversationActive)
        #expect(voice.cancelCalled)
        #expect(vm.localDiscussion == nil)
        #expect(chat.endSessionCount == 1)
    }

    @Test("with no mic, the handoff gives the cursor back")
    internal func handoffRefocusesWhenTyping() async {
        let (vm, _, voice, _) = makeViewModel()
        voice.isEnabledAndAvailable = false
        await vm.startLocalDiscussion()
        await vm.submitLocalDiscussionInput("one change or two?")

        await vm.handLocalDiscussionToAgent()
        #expect(!vm.isConversationActive)
        #expect(vm.refocusInput == 1)
    }

    @Test("with no sessions to draw on, a discussion still opens")
    internal func opensWithoutABriefing() async {
        let (vm, chat, _, _) = makeViewModel()
        // The gateway being down means an empty session list; the local path does
        // not depend on it.
        await vm.startLocalDiscussion()
        await vm.submitLocalDiscussionInput("what should I ask for?")
        #expect(vm.localDiscussion?.briefing.entries.isEmpty == true)
        #expect(chat.instructions.first?.contains("Recent work on this machine") == false)
        #expect(chat.prompts == ["what should I ask for?"])
    }

    @Test("the composer button does nothing until the user has opted in")
    internal func composerRequiresOptIn() async {
        let (vm, chat, _, _) = makeViewModel()
        chat.isEnabled = false
        await vm.startLocalDiscussion()
        #expect(vm.localDiscussion == nil)
        #expect(chat.prepareCount == 0)
    }

    private static var sessions: [Session] {
        [
            Session(id: "a", title: "Wiki space discovery fix", preview: "pushed as #492", messageCount: 34),
            Session(id: "b", title: "Harness forkdiff CI gate", preview: "base pinned", messageCount: 88)
        ]
    }

    /// Spin the runloop until `predicate` holds — local replies stream from a
    /// child task, so effects settle asynchronously.
    private func settle(_ predicate: @escaping () -> Bool) async {
        for _ in 0..<10_000 where !predicate() { await Task.yield() }
    }
}
