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
        #expect(prompt.contains("ONLY the quoted reply"))
    }

    @Test("no options means no options list")
    internal func instructionsOmitEmptyOptions() {
        let discussion = LocalDiscussion(anchorID: UUID(), anchorText: "Just do it.")
        #expect(!discussion.instructions().contains("offered these options"))
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
