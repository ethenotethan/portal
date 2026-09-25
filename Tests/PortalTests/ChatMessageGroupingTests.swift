import Testing
@testable import Portal

/// Group boundaries decide which bubbles carry a timestamp: the last message in
/// a run of consecutive same-role messages shows one, the rest stay bare.
///
/// Both helpers are called from `ForEach` bodies, so their cost is what these
/// tests are ultimately about — the searching version they replaced was O(N) per
/// row, and SwiftUI re-runs a body on every layout pass, not once per change.
/// The behavior assertions below are what let that change be a refactor.
/// `@MainActor` because every helper under test is a `ChatView` static, and
/// `ChatView` is a SwiftUI `View` — so its members inherit main-actor isolation.
/// Calling them from a nonisolated test body is what produced a wall of
/// `#ActorIsolatedCall` warnings (most of them inside `#expect` macro
/// expansions, which report no source file and so were invisible to the warning
/// collector). These are synchronous pure functions over value types, so running
/// the suite on the main actor costs nothing and matches where the renderer
/// actually calls them.
@Suite("Chat message grouping")
@MainActor
internal struct ChatMessageGroupingTests {

    private static func messages(_ roles: [ChatMessage.Role]) -> [ChatMessage] {
        roles.enumerated().map { ChatMessage(role: $0.element, content: "m\($0.offset)") }
    }

    // MARK: - isLastMessageInGroup(at:in:)

    @Test("a role change ends the group; the message before it doesn't")
    internal func boundaryAtRoleChange() {
        let msgs = Self.messages([.user, .assistant, .assistant, .user])
        #expect(ChatView.isLastMessageInGroup(at: 0, in: msgs))   // user → assistant
        #expect(!ChatView.isLastMessageInGroup(at: 1, in: msgs))  // assistant → assistant
        #expect(ChatView.isLastMessageInGroup(at: 2, in: msgs))   // assistant → user
    }

    @Test("the final message is always a boundary — nothing follows it")
    internal func lastMessageIsBoundary() {
        let msgs = Self.messages([.user, .assistant])
        #expect(ChatView.isLastMessageInGroup(at: 1, in: msgs))
        #expect(ChatView.isLastMessageInGroup(at: 0, in: Self.messages([.user])))
    }

    @Test("a run of same-role messages marks only its last member")
    internal func onlyLastOfRunIsMarked() {
        let msgs = Self.messages([.assistant, .assistant, .assistant])
        #expect(!ChatView.isLastMessageInGroup(at: 0, in: msgs))
        #expect(!ChatView.isLastMessageInGroup(at: 1, in: msgs))
        #expect(ChatView.isLastMessageInGroup(at: 2, in: msgs))
    }

    @Test("an out-of-range index reads as a boundary, and an empty list can't crash")
    internal func outOfRangeIsBoundary() {
        // The searching version returned true when the id wasn't found, and a
        // stray timestamp is a cosmetic slip where a crash is not. `renderedMessages`
        // enumerates before filtering, so a stale index during a transcript
        // mutation must land here rather than trapping on a bad subscript.
        let msgs = Self.messages([.user, .assistant])
        #expect(ChatView.isLastMessageInGroup(at: 99, in: msgs))
        #expect(ChatView.isLastMessageInGroup(at: -1, in: msgs))
        #expect(ChatView.isLastMessageInGroup(at: 0, in: []))
    }

    // MARK: - lastInGroupIDs

    @Test("the id set marks exactly the messages that end a run")
    internal func idSetMarksBoundaries() {
        let msgs = Self.messages([.user, .assistant, .assistant, .user, .user])
        let ids = ChatView.lastInGroupIDs(msgs)
        #expect(ids.contains(msgs[0].id))
        #expect(!ids.contains(msgs[1].id))
        #expect(ids.contains(msgs[2].id))
        #expect(!ids.contains(msgs[3].id))
        #expect(ids.contains(msgs[4].id))
        #expect(ids.count == 3)
    }

    @Test("the id set agrees with the index helper on every position")
    internal func idSetAgreesWithIndexHelper() {
        // Two entry points to one rule — a caller with an index and a caller
        // without. They must not drift, or the same transcript would timestamp
        // differently in the chat view and the conversation panel.
        let msgs = Self.messages([.user, .user, .assistant, .user, .assistant, .assistant])
        let ids = ChatView.lastInGroupIDs(msgs)
        for (index, message) in msgs.enumerated() {
            #expect(
                ids.contains(message.id) == ChatView.isLastMessageInGroup(at: index, in: msgs),
                "disagreement at \(index)"
            )
        }
    }

    @Test("an empty transcript yields no boundaries")
    internal func emptyTranscript() {
        #expect(ChatView.lastInGroupIDs([]).isEmpty)
    }

    @Test("a single message is its own boundary")
    internal func singleMessage() {
        let msgs = Self.messages([.assistant])
        #expect(ChatView.lastInGroupIDs(msgs) == [msgs[0].id])
    }

    @Test("alternating roles make every message a boundary")
    internal func alternatingRoles() {
        let msgs = Self.messages([.user, .assistant, .user, .assistant])
        #expect(ChatView.lastInGroupIDs(msgs).count == msgs.count)
    }

    @Test("a long transcript resolves every boundary without a per-row scan")
    internal func longTranscript() {
        // 2_000 messages is ~4M id comparisons under the old per-row search and
        // 2_000 under this one. The assertion is correctness at scale; the point
        // is that this test returns promptly rather than crawling.
        let roles: [ChatMessage.Role] = (0..<2_000).map { $0.isMultiple(of: 3) ? .user : .assistant }
        let msgs = Self.messages(roles)
        let ids = ChatView.lastInGroupIDs(msgs)
        // Asserted as the defining property rather than a hand-derived count:
        // 2_000 isn't a multiple of 3, so the trailing partial group makes any
        // closed-form guess a trap — and it's the rule, not the total, that the
        // renderer depends on.
        let expected = msgs.indices.filter { ChatView.isLastMessageInGroup(at: $0, in: msgs) }
        #expect(ids.count == expected.count)
        #expect(ids == Set(expected.map { msgs[$0].id }))
        // Pattern u,a,a repeating: the user and the second assistant end runs.
        #expect(ids.contains(msgs[0].id))
        #expect(!ids.contains(msgs[1].id))
        #expect(ids.contains(msgs[2].id))
        // And the last message, mid-pattern though it is.
        #expect(ids.contains(msgs[1_999].id))
    }

    // MARK: - prepareBubbleMessage

    @Test("preparing a bubble sets the timestamp flag and always hides the avatar")
    internal func prepareBubbleMessageFlags() {
        // The avatar is drawn by the traveling-avatar overlay, not the bubble, so
        // a bubble that drew its own would double it.
        let message = ChatMessage(role: .assistant, content: "hi")
        let shown = ChatView.prepareBubbleMessage(message, showTimestamp: true)
        #expect(shown.showTimestamp)
        #expect(!shown.showAvatar)

        let hidden = ChatView.prepareBubbleMessage(message, showTimestamp: false)
        #expect(!hidden.showTimestamp)
        #expect(!hidden.showAvatar)
        // Identity and content survive — grouping must not mint a new message.
        #expect(hidden.id == message.id)
        #expect(hidden.content == "hi")
    }
}
