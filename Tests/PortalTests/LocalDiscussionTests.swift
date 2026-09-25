import Foundation
import Testing
@testable import Portal

@Suite("Local discussion model")
internal struct LocalDiscussionTests {

    // MARK: - Anchor trimming

    @Test("a short anchor is kept whole")
    internal func shortAnchorKept() {
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: "  Use the actor.  ")
        #expect(discussion.anchorText == "Use the actor.")
    }

    @Test("a long anchor is cut at a paragraph boundary past half the budget")
    internal func longAnchorCutOnParagraph() {
        let head = String(repeating: "a", count: 1_000)
        let tail = String(repeating: "b", count: 1_000)
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: head + "\n\n" + tail)
        // The break sits past half the budget, so the head survives intact and
        // nothing is handed over mid-paragraph.
        #expect(discussion.anchorText == head)
    }

    @Test("a long anchor with no late paragraph break is cut at the budget")
    internal func longAnchorHardCut() {
        let text = String(repeating: "x", count: 4_000)
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: text)
        #expect(discussion.anchorText.count == LocalDiscussion.anchorBudget)
    }

    @Test("an early paragraph break is not used as the cut")
    internal func earlyParagraphIgnored() {
        // A break in the first half would throw away most of the budget.
        let text = "intro\n\n" + String(repeating: "y", count: 4_000)
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: text)
        #expect(discussion.anchorText.count == LocalDiscussion.anchorBudget)
    }

    // MARK: - Option detection

    @Test("lettered options are recognized")
    internal func detectsLetteredOptions() {
        let text = """
        Here are the ways to do it:

        A. Keep the session in an actor
        B. Rebuild it per call
        C. Do nothing for now
        """
        #expect(LocalDiscussion.detectOptions(in: text) == [
            "Keep the session in an actor",
            "Rebuild it per call",
            "Do nothing for now"
        ])
    }

    @Test("bulleted and bolded option markers are recognized")
    internal func detectsDecoratedOptions() {
        let text = """
        - **Option A)** Ship the fix
        - **Option B)** Rewrite the layer
        """
        #expect(LocalDiscussion.detectOptions(in: text) == ["Ship the fix", "Rewrite the layer"])
    }

    @Test("a lone marker is a step, not a choice")
    internal func singleMarkerIsNotAnOption() {
        #expect(LocalDiscussion.detectOptions(in: "1. Run the build").isEmpty)
    }

    @Test("prose with no enumeration yields no options")
    internal func proseYieldsNoOptions() {
        // The point of not reusing the reasoning summarizer: no fabricated
        // fallback option.
        let text = "I'd keep the session in an actor. It's the only safe place for it."
        #expect(LocalDiscussion.detectOptions(in: text).isEmpty)
    }

    @Test("a numbered paragraph is too long to be a spoken option")
    internal func longLinesAreNotOptions() {
        let text = """
        1. \(String(repeating: "z", count: 300))
        2. \(String(repeating: "w", count: 300))
        """
        #expect(LocalDiscussion.detectOptions(in: text).isEmpty)
    }

    @Test("at most six options are carried")
    internal func optionsAreCapped() {
        let text = (1...9).map { "\($0). option \($0)" }.joined(separator: "\n")
        #expect(LocalDiscussion.detectOptions(in: text).count == 6)
    }

    // MARK: - Prompting

    @Test("instructions ground the model in the reply and its options")
    internal func instructionsIncludeGrounding() {
        let discussion = LocalDiscussion(
            anchorID: UUID(),
            anchorText: "Use an actor for the session.",
            options: ["Actor", "Per-call session"]
        )
        let prompt = discussion.instructions()
        #expect(prompt.contains("Use an actor for the session."))
        #expect(prompt.contains("1. Actor"))
        #expect(prompt.contains("2. Per-call session"))
        // The three rules that matter when this is read aloud.
        #expect(prompt.contains("SPOKEN"))
        #expect(prompt.contains("No markdown"))
        #expect(prompt.contains("The context below is ALL you can see"))
        // Anchored, the subject is the reply — not a fresh planning session.
        #expect(prompt.contains("a reply they just received"))
        #expect(prompt.contains("The reply under discussion:"))
        #expect(!prompt.contains("working out what to ask"))
    }

    @Test("no options means no options list")
    internal func instructionsOmitEmptyOptions() {
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Just do it.")
        #expect(!discussion.instructions().contains("offered these options"))
    }

    @Test("a composer-started discussion is briefed instead of anchored")
    internal func unanchoredInstructionsUseTheBriefing() {
        let briefing = LocalDiscussionBriefing.build(
            from: [
                LocalDiscussionTests.session(id: "a", title: "Forkdiff CI gate", preview: "base pinned"),
                LocalDiscussionTests.session(id: "b", title: "Wiki space picker", preview: "PR #492 open")
            ]
        )
        let discussion = LocalDiscussion(
            anchorID: UUID(),
            draftText: "Here's a design for the cron digest.",
            briefing: briefing
        )
        let prompt = discussion.instructions()
        #expect(!discussion.isAnchored)
        // "What are we working on today?" is answerable now — this is the whole
        // point of the briefing.
        #expect(prompt.contains("Forkdiff CI gate"))
        #expect(prompt.contains("Wiki space picker"))
        #expect(prompt.contains("answer from the session list"))
        #expect(prompt.contains("before they ask a coding agent to do anything"))
        // The draft is labelled as unsent, so the model doesn't discuss it as
        // though the agent had already replied to it.
        #expect(prompt.contains("NOT yet sent to the agent"))
        #expect(prompt.contains("Here's a design for the cron digest."))
        #expect(!prompt.contains("The reply under discussion:"))
    }

    @Test("an empty composer with nothing open still yields usable instructions")
    internal func unanchoredWithNoContext() {
        let prompt = LocalDiscussion(anchorID: UUID()).instructions()
        #expect(prompt.contains("SPOKEN"))
        // No headings for context that doesn't exist — an empty "Recent work"
        // list is an invitation to invent one.
        #expect(!prompt.contains("Recent work on this machine"))
        #expect(!prompt.contains("drafted so far"))
        #expect(!prompt.contains("The reply under discussion:"))
    }

    @Test("a briefing is included when discussing a reply too")
    internal func anchoredInstructionsAlsoCarryTheBriefing() {
        let discussion = LocalDiscussion(
            anchorID: UUID(),
            anchorText: "Use an actor.",
            briefing: LocalDiscussionBriefing.build(
                from: [LocalDiscussionTests.session(id: "a", title: "Local discussion feature")]
            )
        )
        let prompt = discussion.instructions()
        #expect(prompt.contains("Local discussion feature"))
        #expect(prompt.contains("The reply under discussion:"))
    }

    private static func session(id: String, title: String, preview: String? = nil) -> Session {
        Session(id: id, title: title, preview: preview, messageCount: 2)
    }

    @Test("the handoff labels who said what and drops empty turns")
    internal func handoffPromptLabelsSpeakers() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "why the actor?"),
            LocalDiscussionTurn(role: .assistant, text: "because the session isn't Sendable"),
            LocalDiscussionTurn(role: .assistant, text: "   ")
        ]
        let prompt = discussion.handoffPrompt()
        #expect(prompt.contains("Me: why the actor?"))
        #expect(prompt.contains("Local model: because the session isn't Sendable"))
        // The blank turn contributes no stray label.
        #expect(prompt.components(separatedBy: "Local model:").count == 2)
        // The agent is told how much to trust each side.
        #expect(prompt.contains("unverified scratch thinking"))
        #expect(prompt.contains("talked your last reply over"))
    }

    @Test("a pre-send handoff carries the draft, since it replaces the composer")
    internal func unanchoredHandoffKeepsTheDraft() {
        var discussion = LocalDiscussion(
            anchorID: UUID(),
            draftText: "Rework the cron digest so source files stay out of it."
        )
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "is that one change or two?"),
            LocalDiscussionTurn(role: .assistant, text: "two — the digest and the node surface")
        ]
        let prompt = discussion.handoffPrompt()
        // Submitting the conversation replaces whatever was in the composer, so
        // leaving the draft out would silently eat what the user pasted there.
        #expect(prompt.contains("Rework the cron digest so source files stay out of it."))
        #expect(prompt.contains("What I had drafted going in:"))
        #expect(prompt.contains("Before asking you for anything"))
        #expect(!prompt.contains("talked your last reply over"))
    }

    @Test("a discussion has nothing to hand over until the model has answered")
    internal func hasExchangeRequiresAnAnswer() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        #expect(!discussion.hasExchange)
        discussion.turns = [LocalDiscussionTurn(role: .user, text: "why?")]
        #expect(!discussion.hasExchange)
        discussion.turns.append(LocalDiscussionTurn(role: .assistant, text: "because"))
        #expect(discussion.hasExchange)
    }

    // MARK: - Resuming

    @Test("resuming re-states the exchange, since the engine has forgotten it")
    internal func resumingGroundsInTheExchange() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "why the actor?"),
            LocalDiscussionTurn(role: .assistant, text: "because the session isn't Sendable")
        ]

        let resumed = discussion.resuming()
        let prompt = resumed.instructions()
        #expect(resumed.recap.count == 2)
        #expect(prompt.contains("Earlier in this same conversation"))
        #expect(prompt.contains("Me: why the actor?"))
        #expect(prompt.contains("Local model: because the session isn't Sendable"))
    }

    @Test("the resume grounding is frozen, so the KV cache survives the next turn")
    internal func recapDoesNotTrackNewTurns() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "why?"),
            LocalDiscussionTurn(role: .assistant, text: "because")
        ]
        var resumed = discussion.resuming()
        let first = resumed.instructions()

        resumed.turns.append(LocalDiscussionTurn(role: .user, text: "and the cache?"))
        resumed.turns.append(LocalDiscussionTurn(role: .assistant, text: "it stays warm"))
        // Instructions that grew with the exchange would rebuild the engine's chat
        // session on every single turn — the thing the recap snapshot exists to avoid.
        #expect(resumed.instructions() == first)
        #expect(resumed.recap.count == 2)
    }

    @Test("resuming an untouched discussion changes nothing")
    internal func resumingEmptyIsANoop() {
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        #expect(discussion.resuming() == discussion)
        #expect(!discussion.resuming().instructions().contains("Earlier in this same conversation"))
    }

    @Test("the seam is where the new sitting starts, and only once there is one")
    internal func resumedAtMarksTheSecondSitting() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        // One sitting: nothing to mark.
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "why?"),
            LocalDiscussionTurn(role: .assistant, text: "because")
        ]
        #expect(discussion.resumedAt == nil)

        // Picked up, but nothing said yet — a marker at the very end marks nothing.
        var resumed = discussion.resuming()
        #expect(resumed.resumedAt == nil)

        resumed.turns.append(LocalDiscussionTurn(role: .user, text: "and the cache?"))
        #expect(resumed.resumedAt == 2)
    }

    // MARK: - Drafting the ask

    @Test("the drafting pass gets the grounding and the whole exchange")
    internal func draftingPromptCarriesEverything() {
        var discussion = LocalDiscussion(
            anchorID: UUID(),
            anchorText: "Reply with A, B, or C.",
            draftText: "Rework the digest."
        )
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "which one?"),
            LocalDiscussionTurn(role: .assistant, text: "B, it's the smallest change")
        ]
        discussion = discussion.resuming()
        discussion.turns.append(LocalDiscussionTurn(role: .user, text: "ok"))

        let prompt = discussion.draftingPrompt()
        #expect(prompt.contains("Reply with A, B, or C."))
        #expect(prompt.contains("Rework the digest."))
        #expect(prompt.contains("Me: which one?"))
        #expect(prompt.contains("Local model: B, it's the smallest change"))
        // Turns from before a resume are part of the conversation too, and appear
        // once rather than twice.
        #expect(prompt.components(separatedBy: "Me: which one?").count == 2)
    }

    @Test("the drafting instructions are not the spoken ones")
    internal func draftingInstructionsDifferFromTheDiscussion() {
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        let drafting = discussion.draftingInstructions()
        // Different text is also what makes the engine build a clean session rather
        // than keep writing in the voice it used for speech.
        #expect(drafting != discussion.instructions())
        #expect(!drafting.contains("speech synthesizer"))
        #expect(drafting.contains(LocalDiscussion.noAskSentinel))
    }

    @Test("a drafted ask is unwrapped and accepted")
    internal func usableAskCleansTheDraft() {
        #expect(LocalDiscussion.usableAsk("  \"Move the digest behind a flag.\"  ")
                == "Move the digest behind a flag.")
        #expect(LocalDiscussion.usableAsk("<think>hmm</think>Move it.") == "Move it.")
    }

    @Test("a declined, empty, or runaway draft is rejected")
    internal func usableAskRejectsNonAnswers() {
        #expect(LocalDiscussion.usableAsk(LocalDiscussion.noAskSentinel) == nil)
        #expect(LocalDiscussion.usableAsk("nothing settled here") == nil)
        #expect(LocalDiscussion.usableAsk("   ") == nil)
        #expect(LocalDiscussion.usableAsk("<think>only reasoning") == nil)
        let runaway = String(repeating: "x", count: LocalDiscussion.draftedAskBudget + 1)
        #expect(LocalDiscussion.usableAsk(runaway) == nil)
    }

    @Test("the drafted ask leads the handoff, with the exchange behind it")
    internal func handoffLeadsWithTheAsk() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "which one?"),
            LocalDiscussionTurn(role: .assistant, text: "B")
        ]
        let prompt = discussion.handoffPrompt(ask: "Take option B and keep the actor.")
        // The instruction is the output the conversation was for, so it comes first
        // and the reasoning follows as context.
        #expect(prompt.hasPrefix("Take option B and keep the actor."))
        #expect(prompt.contains("Me: which one?"))
        #expect(!prompt.contains("Pick this up from here."))
    }

    @Test("with no usable ask the transcript still stands on its own")
    internal func handoffFallsBackToTheTranscript() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "which one?"),
            LocalDiscussionTurn(role: .assistant, text: "B")
        ]
        // A failed write-up must not lose the conversation.
        #expect(discussion.handoffPrompt(ask: nil).contains("Pick this up from here."))
        #expect(discussion.handoffPrompt(ask: "").contains("Me: which one?"))
    }

    @Test("a resumed discussion hands over the whole thread, not just the last sitting")
    internal func handoffIncludesTheRecap() {
        var discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Anchor")
        discussion.turns = [
            LocalDiscussionTurn(role: .user, text: "first question"),
            LocalDiscussionTurn(role: .assistant, text: "first answer")
        ]
        var resumed = discussion.resuming()
        resumed.turns.append(LocalDiscussionTurn(role: .user, text: "second question"))
        resumed.turns.append(LocalDiscussionTurn(role: .assistant, text: "second answer"))

        let prompt = resumed.handoffPrompt(ask: "Do the thing.")
        #expect(prompt.contains("Me: first question"))
        #expect(prompt.contains("Me: second question"))
        #expect(prompt.components(separatedBy: "Me: first question").count == 2)
    }
}

@Suite("Local discussion close-out")
internal struct LocalDiscussionCloseOutTests {

    @Test("the ways people say they're done", arguments: [
        "submit",
        "Okay, let's submit.",
        "ok cool, so let's just submit this",
        "send it",
        "send it over to Claude, please",
        "go ahead",
        "go for it",
        "alright, continue",
        "yep, do it",
        "ship it",
        "run with it",
        "hand it over",
        "take it from here",
        "that's it",
        "please submit that now",
        "OK GO",
        // Chained: what people actually say when they mean it.
        "let's continue",
        "okay, let's continue and send it",
        "go ahead and submit that",
        "can you go ahead and submit that now",
        "continue the session",
        "send the prompt over",
        "alright, submit it and continue"
    ])
    internal func recognizesCloseOuts(_ utterance: String) {
        #expect(LocalDiscussionCloseOut.isCloseOut(utterance))
    }

    @Test("questions and asides are not close-outs", arguments: [
        "why the actor?",
        "go on",
        "keep going",
        "go ahead and explain why B is cheaper",
        "should we send it to the agent or rethink it",
        "what do you think",
        "yes",
        "no",
        "hold on",
        "what are we working on today?",
        "so does that mean we run it twice",
        "",
        "   ",
        "start over",
        "let's talk about the cache instead"
    ])
    internal func rejectsEverythingElse(_ utterance: String) {
        // A false positive spends a gateway turn on a half-finished thought, so this
        // is the side of the line that has to be right.
        #expect(!LocalDiscussionCloseOut.isCloseOut(utterance))
    }
}

@Suite("Local reply text")
internal struct LocalReplyTextTests {

    @Test("reasoning blocks and filler are stripped")
    internal func cleanStripsThinkAndFiller() {
        let raw = "<think>The user asks about actors. I should mention Sendable.</think>Sure! **Actors** work."
        #expect(LocalReplyText.clean(raw) == "Actors work.")
    }

    @Test("a reply with no artifacts is untouched")
    internal func cleanKeepsPlainText() {
        #expect(LocalReplyText.clean("  Keep the actor.  ") == "Keep the actor.")
    }

    @Test("an unterminated reasoning block leaves nothing to say")
    internal func cleanDropsUnclosedThink() {
        #expect(LocalReplyText.clean("<think>still thinking about it").isEmpty)
    }
}

@Suite("Think block filter")
internal struct ThinkBlockFilterTests {

    @Test("text around a reasoning block is emitted, the block is not")
    internal func filtersWholeBlock() {
        var filter = ThinkBlockFilter()
        let visible = filter.feed("before<think>hidden</think>after")
        #expect(visible + filter.finish() == "beforeafter")
    }

    @Test("a tag split across deltas is still caught")
    internal func filtersSplitTag() {
        var filter = ThinkBlockFilter()
        var visible = ""
        // The exact failure this state machine exists for: a token boundary in
        // the middle of "<think>" would leak "<thi" onto the screen.
        for delta in ["Hello ", "<thi", "nk>secret rea", "soning</thi", "nk>", "world"] {
            visible += filter.feed(delta)
        }
        visible += filter.finish()
        #expect(visible == "Hello world")
    }

    @Test("a partial tag that turns out to be ordinary text is released")
    internal func releasesFalseStart() {
        var filter = ThinkBlockFilter()
        var visible = filter.feed("compare a < b")
        visible += filter.feed(" always")
        visible += filter.finish()
        #expect(visible == "compare a < b always")
    }

    @Test("multiple blocks in one stream are all suppressed")
    internal func filtersRepeatedBlocks() {
        var filter = ThinkBlockFilter()
        let visible = filter.feed("a<think>1</think>b<think>2</think>c")
        #expect(visible + filter.finish() == "abc")
    }

    @Test("a stream ending inside a block yields nothing further")
    internal func dropsUnfinishedBlock() {
        var filter = ThinkBlockFilter()
        let visible = filter.feed("answer<think>still going")
        #expect(visible == "answer")
        #expect(filter.finish().isEmpty)
    }

    @Test("one-shot stripping matches the streaming result")
    internal func stripAllMatchesStreaming() {
        let raw = "one<think>hidden</think>two"
        #expect(ThinkBlockFilter.stripAll(from: raw) == "onetwo")
    }
}
