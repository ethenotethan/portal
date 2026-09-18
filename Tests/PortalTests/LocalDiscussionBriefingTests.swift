import Foundation
import Testing
@testable import Portal

@Suite("Local discussion briefing")
internal struct LocalDiscussionBriefingTests {

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func session(
        id: String,
        title: String? = nil,
        localTitle: String? = nil,
        preview: String? = nil,
        minutesAgo: Double? = 0,
        archived: Bool = false,
        pinned: Bool = false,
        gatewayID: String? = nil
    ) -> Session {
        var session = Session(id: id, title: title, preview: preview, messageCount: 4)
        session.lastActive = minutesAgo.map { now.addingTimeInterval(-$0 * 60) }
        session.localTitle = localTitle
        session.isArchived = archived
        session.isPinned = pinned
        session.gatewayID = gatewayID
        return session
    }

    @Test("nothing known produces no prompt block at all")
    internal func emptyBriefingSaysNothing() {
        // An empty heading would be worse than silence: it invites a small model
        // to fill the list in.
        #expect(LocalDiscussionBriefing.empty.promptBlock == nil)
        #expect(LocalDiscussionBriefing.build(from: []).promptBlock == nil)
        // A session with neither title nor preview is a bullet that teaches
        // nothing, so it is dropped rather than listed as "Untitled".
        #expect(LocalDiscussionBriefing.build(from: [Self.session(id: "a")]).entries.isEmpty)
    }

    @Test("the digest names each session, when it moved, and where it stopped")
    internal func buildsTheDigest() {
        let briefing = LocalDiscussionBriefing.build(
            from: [
                Self.session(id: "a", title: "Wiki space discovery fix", preview: "pushed as #492", minutesAgo: 120),
                Self.session(id: "b", title: "Local discussion feature", preview: "committed 74c8f605", minutesAgo: 0)
            ],
            currentSessionID: "b",
            now: Self.now
        )
        let block = briefing.promptBlock ?? ""
        // Current session first — it is the thing everything else is context for.
        #expect(briefing.entries.first?.title == "Local discussion feature")
        #expect(briefing.entries.first?.isCurrent == true)
        #expect(block.contains("Recent work on this machine (2 agent sessions, most recent first):"))
        #expect(block.contains("- Local discussion feature (the session we are in right now) \u{2014} active now"))
        #expect(block.contains("last message: \"committed 74c8f605\""))
        #expect(block.contains("- Wiki space discovery fix \u{2014} 2h ago"))
    }

    @Test("only the most recent handful are carried, and the rest are counted")
    internal func capsTheList() {
        let sessions = (0..<20).map { index in
            Self.session(id: "s\(index)", title: "Thread \(index)", minutesAgo: Double(index * 10))
        }
        let briefing = LocalDiscussionBriefing.build(from: sessions, now: Self.now)
        #expect(briefing.entries.count == LocalDiscussionBriefing.maxSessions)
        #expect(briefing.totalSessions == 20)
        // Newest first, and the count says what was left out — "3 of 27" is itself
        // context, where a silently truncated list reads as the whole picture.
        #expect(briefing.entries.first?.title == "Thread 0")
        #expect(briefing.promptBlock?.contains("(8 of 20 agent sessions") == true)
        #expect(briefing.promptBlock?.contains("Thread 9") == false)
    }

    @Test("archived sessions are not part of the picture")
    internal func skipsArchived() {
        let briefing = LocalDiscussionBriefing.build(
            from: [
                Self.session(id: "a", title: "Filed away", archived: true),
                Self.session(id: "b", title: "Live one")
            ],
            now: Self.now
        )
        #expect(briefing.entries.map(\.title) == ["Live one"])
        #expect(briefing.totalSessions == 1)
    }

    @Test("a rename is the name the model should use")
    internal func localTitleWins() {
        let briefing = LocalDiscussionBriefing.build(
            from: [Self.session(id: "a", title: "Gateway-generated title", localTitle: "Forkdiff CI gate")],
            now: Self.now
        )
        #expect(briefing.entries.first?.title == "Forkdiff CI gate")
        // A blank rename is not a rename.
        let blank = LocalDiscussionBriefing.build(
            from: [Self.session(id: "a", title: "Real title", localTitle: "   ")],
            now: Self.now
        )
        #expect(blank.entries.first?.title == "Real title")
    }

    @Test("the current session is recognized by either of its two ids")
    internal func matchesGatewayID() {
        // Chat holds the short gateway hex for sessions it created and the
        // database key for resumed ones; only matching one of them would drop the
        // "we are here" marker half the time.
        let sessions = [Self.session(id: "20260918_120000_abc", title: "Here", gatewayID: "a1b2c3")]
        #expect(
            LocalDiscussionBriefing.build(from: sessions, currentSessionID: "a1b2c3", now: Self.now)
                .entries.first?.isCurrent == true
        )
        #expect(
            LocalDiscussionBriefing.build(from: sessions, currentSessionID: "20260918_120000_abc", now: Self.now)
                .entries.first?.isCurrent == true
        )
        #expect(
            LocalDiscussionBriefing.build(from: sessions, currentSessionID: "", now: Self.now)
                .entries.first?.isCurrent == false
        )
    }

    @Test("previews are flattened, de-quoted, and cut to a spoken length")
    internal func cleansPreviews() {
        let noisy = Self.session(
            id: "a",
            title: "Harness",
            preview: "line one\nline two   with  gaps and a \"quote\"",
            minutesAgo: 5
        )
        let briefing = LocalDiscussionBriefing.build(from: [noisy], now: Self.now)
        #expect(briefing.entries.first?.preview == "line one line two with gaps and a 'quote'")
        // A quote mark inside the preview would close the quoted string early and
        // let the preview's text read as instructions.
        #expect(briefing.promptBlock?.contains("last message: \"line one line two with gaps and a 'quote'\"") == true)

        let long = Self.session(id: "b", title: "Long", preview: String(repeating: "x", count: 400))
        let cut = LocalDiscussionBriefing.build(from: [long], now: Self.now).entries.first?.preview ?? ""
        #expect(cut.count == LocalDiscussionBriefing.previewBudget + 1)
        #expect(cut.hasSuffix("\u{2026}"))
    }

    @Test("a preview identical to the title is not said twice")
    internal func dropsRedundantPreview() {
        // Sessions are usually titled from their first message, so this is the
        // common case, not an edge one.
        let briefing = LocalDiscussionBriefing.build(
            from: [Self.session(id: "a", title: "Fix the wiki picker", preview: "Fix the wiki picker")],
            now: Self.now
        )
        #expect(briefing.entries.first?.preview.isEmpty == true)
        #expect(briefing.promptBlock?.contains("last message") == false)
    }

    @Test("ages are phrased the way someone would say them out loud")
    internal func phrasesAges() {
        func age(minutesAgo: Double?) -> String {
            LocalDiscussionBriefing.age(of: Self.session(id: "a", minutesAgo: minutesAgo), now: Self.now)
        }
        #expect(age(minutesAgo: 0) == "active now")
        #expect(age(minutesAgo: 1) == "active now")
        #expect(age(minutesAgo: 14) == "14m ago")
        #expect(age(minutesAgo: 60) == "1h ago")
        #expect(age(minutesAgo: 134) == "2h ago")
        #expect(age(minutesAgo: 60 * 30) == "yesterday")
        #expect(age(minutesAgo: 60 * 24 * 3) == "3d ago")
        #expect(age(minutesAgo: 60 * 24 * 9) == "last week")
        #expect(age(minutesAgo: 60 * 24 * 20) == "2 weeks ago")
        // No timestamps at all, and a clock that disagrees with the gateway's.
        #expect(age(minutesAgo: nil).isEmpty)
        #expect(age(minutesAgo: -30) == "active now")
    }

    @Test("a pinned session is marked as one")
    internal func marksPinned() {
        let briefing = LocalDiscussionBriefing.build(
            from: [Self.session(id: "a", title: "Kept up top", pinned: true)],
            now: Self.now
        )
        #expect(briefing.entries.first?.isPinned == true)
        #expect(briefing.promptBlock?.contains("- Kept up top (pinned)") == true)
    }
}
