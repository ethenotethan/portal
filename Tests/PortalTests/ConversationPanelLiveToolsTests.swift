import Foundation
import Testing
@testable import Portal

@Suite("Live tool calls in the chat transcript")
internal struct ConversationPanelLiveToolsTests {
    private func record(
        _ id: String,
        name: String,
        startedAt: Date? = nil,
        isComplete: Bool = false
    ) -> ToolCallRecord {
        ToolCallRecord(id: id, name: name, isComplete: isComplete, startedAt: startedAt)
    }

    private func streamingReply() -> ChatMessage {
        ChatMessage(role: .assistant, content: "Working on it", isStreaming: true)
    }

    @Test("A running turn adopts the in-flight records the view model is holding")
    internal func streamingTurnAdoptsLiveRecords() {
        // The bug: the turn's tools card stayed empty until message.complete,
        // because ChatMessage.toolCalls is only stamped there.
        let live = [
            "b": record("b", name: "Edit", startedAt: Date(timeIntervalSince1970: 20)),
            "a": record("a", name: "Read", startedAt: Date(timeIntervalSince1970: 10))
        ]
        let merged = ConversationPanel.mergingLiveToolCalls(
            into: streamingReply(),
            activeToolCalls: live
        )
        #expect(merged.toolCalls.map(\.name) == ["Read", "Edit"])
    }

    @Test("Records stream in start order, with the id as a stable tiebreak")
    internal func liveRecordsSortByStart() {
        let shared = Date(timeIntervalSince1970: 30)
        let ordered = ConversationPanel.liveToolCallOrder([
            "z": record("z", name: "Grep", startedAt: shared),
            "m": record("m", name: "Bash", startedAt: shared),
            "early": record("early", name: "Read", startedAt: Date(timeIntervalSince1970: 5))
        ])
        #expect(ordered.map(\.id) == ["early", "m", "z"])
    }

    @Test("Timing-less history records sort ahead of timed ones instead of dropping out")
    internal func untimedRecordsSortFirst() {
        let ordered = ConversationPanel.liveToolCallOrder([
            "timed": record("timed", name: "Edit", startedAt: Date(timeIntervalSince1970: 1)),
            "untimed": record("untimed", name: "Read")
        ])
        #expect(ordered.map(\.id) == ["untimed", "timed"])
    }

    @Test("A settled turn keeps its own stamped history")
    internal func settledTurnKeepsStampedHistory() {
        // Otherwise the previous turn would borrow the next turn's in-flight
        // records and show tools it never ran.
        var settled = ChatMessage(role: .assistant, content: "Done")
        settled.toolCalls = [record("old", name: "Write", isComplete: true)]
        let merged = ConversationPanel.mergingLiveToolCalls(
            into: settled,
            activeToolCalls: ["new": record("new", name: "Bash")]
        )
        #expect(merged.toolCalls.map(\.name) == ["Write"])
    }

    @Test("A running turn with no tools yet is left alone")
    internal func emptyLiveRecordsLeaveTheTurnUntouched() {
        var streaming = streamingReply()
        streaming.toolCalls = [record("kept", name: "Read", isComplete: true)]
        let merged = ConversationPanel.mergingLiveToolCalls(
            into: streaming,
            activeToolCalls: [:]
        )
        #expect(merged.toolCalls.map(\.id) == ["kept"])
    }

    // MARK: - Windowing the live trail

    private func trail(_ count: Int, isStreaming: Bool) -> ChatMessage {
        var message = ChatMessage(role: .assistant, content: "Working", isStreaming: isStreaming)
        message.toolCalls = (0..<count).map { record("t\($0)", name: "Read") }
        return message
    }

    @Test("A long running turn renders only its most recent rows")
    internal func liveTrailIsWindowed() {
        // A single observed turn fired 59 tool calls; every insert reflowed the
        // whole transcript tree.
        let window = ConversationPanel.toolTrailWindow(for: trail(59, isStreaming: true), limit: 12)
        #expect(window.rows.count == 12)
        #expect(window.rows.first?.id == "t47")
        #expect(window.rows.last?.id == "t58")
    }

    @Test("The windowed card still reports the turn's true tool count")
    internal func windowedTrailReportsTotal() {
        let window = ConversationPanel.toolTrailWindow(for: trail(59, isStreaming: true), limit: 12)
        #expect(window.total == 59)
    }

    @Test("A settled turn renders its whole trail")
    internal func settledTrailIsNotWindowed() {
        let window = ConversationPanel.toolTrailWindow(for: trail(59, isStreaming: false), limit: 12)
        #expect(window.rows.count == 59)
        #expect(window.total == 59)
    }

    @Test("A running turn at or under the limit is untouched")
    internal func shortLiveTrailIsNotWindowed() {
        let window = ConversationPanel.toolTrailWindow(for: trail(12, isStreaming: true), limit: 12)
        #expect(window.rows.count == 12)
        #expect(window.rows.first?.id == "t0")
    }
}
