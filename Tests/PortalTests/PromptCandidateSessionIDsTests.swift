import XCTest
@testable import Portal

/// The hermes websocket gateway's `session.list` includes ended/historical
/// sessions, but `session.prompt_breakdown` only answers for sessions with a
/// live in-memory agent (4001 otherwise). The system-prompt pane must walk a
/// live-first candidate list instead of erroring on the first stale entry.
internal final class PromptCandidateSessionIDsTests: XCTestCase {

    private func session(
        _ id: String,
        runState: SessionRunState? = nil,
        ended: Bool = false
    ) -> Session {
        Session(
            id: id,
            title: nil,
            preview: nil,
            source: nil,
            messageCount: 0,
            startedAt: nil,
            endedAt: ended ? Date() : nil,
            lastActive: nil,
            runState: runState
        )
    }

    internal func testLiveSessionsRankBeforeUnendedAndEnded() {
        let sessions = [
            session("ended-old", ended: true),
            session("idle-no-end"),
            session("live", runState: .streaming),
        ]
        XCTAssertEqual(
            promptCandidateSessionIDs(sessions),
            ["live", "idle-no-end", "ended-old"]
        )
    }

    internal func testGatewayOrderingPreservedWithinRanks() {
        let sessions = [
            session("live-1", runState: .queued),
            session("ended-1", ended: true),
            session("live-2", runState: .toolRunning),
            session("ended-2", ended: true),
        ]
        XCTAssertEqual(
            promptCandidateSessionIDs(sessions),
            ["live-1", "live-2", "ended-1", "ended-2"]
        )
    }

    internal func testWaitingForUserCountsAsLive() {
        let sessions = [
            session("idle-no-end"),
            session("approval", runState: .waitingForUser),
        ]
        XCTAssertEqual(
            promptCandidateSessionIDs(sessions),
            ["approval", "idle-no-end"]
        )
    }

    internal func testUnknownRunStateWithNoEndRanksMiddle() {
        let sessions = [
            session("ended", ended: true),
            session("unknown-state", runState: nil),
        ]
        XCTAssertEqual(
            promptCandidateSessionIDs(sessions),
            ["unknown-state", "ended"]
        )
    }

    internal func testEmptyListYieldsNoCandidates() {
        XCTAssertEqual(promptCandidateSessionIDs([]), [])
    }
}
