import Testing
@testable import Portal

/// finishThinkingTrace must never destroy thinking that was streamed live.
/// Regression tests for the "thinking disappears / can't expand after the
/// turn" bug: an EMPTY finalReasoning used to wipe the streamed reasoning
/// (`finalReasoning ?? message.reasoning` assigns "" over accumulated text)
/// and no ThinkingTrace was built from raw streamed deltas, so the
/// collapsible trace section vanished at message.complete.
@MainActor
struct FinishThinkingTraceTests {

    private func makeVM() -> ChatViewModel { ChatViewModel() }

    @Test("empty finalReasoning keeps streamed reasoning and promotes it to a trace")
    func emptyFinalReasoningPreservesStreamedReasoning() async throws {
        let vm = makeVM()
        var message = ChatMessage(role: .assistant, content: "answer", status: "complete")
        message.isStreaming = true
        // Simulate the 500ms flush path: raw thinking deltas land in .reasoning
        message.reasoning = "step one: read the config\nstep two: noticed the bug"

        vm.finishThinkingTrace(on: &message, finalReasoning: "")

        #expect(message.reasoning == "step one: read the config\nstep two: noticed the bug",
                "empty finalReasoning must not wipe streamed reasoning")
        let trace = try #require(message.thinkingTrace, "streamed reasoning must be promoted to a ThinkingTrace so the collapsible section survives")
        #expect(!trace.isStreaming)
        #expect(trace.fullText.contains("noticed the bug"))
    }

    @Test("nil finalReasoning with streamed text also promotes to a trace")
    func nilFinalReasoningPromotesStreamedText() async throws {
        let vm = makeVM()
        var message = ChatMessage(role: .assistant, content: "answer", status: "complete")
        message.reasoning = "streamed thought"

        vm.finishThinkingTrace(on: &message, finalReasoning: nil)

        #expect(message.reasoning == "streamed thought")
        let trace = try #require(message.thinkingTrace)
        #expect(trace.fullText == "streamed thought")
        #expect(!trace.isStreaming)
    }

    @Test("non-empty finalReasoning still lands in the trace (unchanged behavior)")
    func nonEmptyFinalReasoningBuildsTrace() async throws {
        let vm = makeVM()
        var message = ChatMessage(role: .assistant, content: "answer", status: "complete")
        message.reasoning = "partial stream"

        vm.finishThinkingTrace(on: &message, finalReasoning: "final polished reasoning")

        let trace = try #require(message.thinkingTrace)
        #expect(trace.fullText.contains("final polished reasoning"))
        #expect(message.reasoning == trace.fullText,
                "legacy field mirrors the trace when the trace is authoritative")
    }

    @Test("existing mid-stream trace (MoA blocks) keeps final reasoning appended")
    func existingTraceGetsFinalReasoningAppended() async throws {
        let vm = makeVM()
        var message = ChatMessage(role: .assistant, content: "answer", status: "complete")
        var trace = ThinkingTrace(isStreaming: true)
        trace.appendDiscreteBlock("reference answer", kind: .moaReference, label: "gpt-4o")
        message.thinkingTrace = trace

        vm.finishThinkingTrace(on: &message, finalReasoning: "aggregated reasoning")

        let finished = try #require(message.thinkingTrace)
        #expect(!finished.isStreaming)
        #expect(finished.blocks.contains { $0.kind == .reasoning })
        #expect(finished.blocks.contains { $0.kind == .moaReference })
    }

    @Test("nothing streamed and nothing finalized leaves the message untouched")
    func nothingStreamedNothingFinalized() {
        let vm = makeVM()
        var message = ChatMessage(role: .assistant, content: "answer", status: "complete")

        vm.finishThinkingTrace(on: &message, finalReasoning: "")

        #expect(message.reasoning == nil || message.reasoning?.isEmpty == true)
        #expect(message.thinkingTrace == nil)
    }
}
