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
}
