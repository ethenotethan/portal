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
        // This text goes back into the composer the draft came from, so leaving
        // the draft out would silently eat what the user pasted there.
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
