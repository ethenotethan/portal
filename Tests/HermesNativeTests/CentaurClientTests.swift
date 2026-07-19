import Testing
import Foundation
@testable import HermesNative

@Suite("Centaur SSE Parser")
struct SSEParserTests {

    @Test("parses a complete frame with id, event, and data")
    func parsesCompleteFrame() {
        var parser = SSEParser()
        #expect(parser.consume(line: "id: 42") == nil)
        #expect(parser.consume(line: "event: session.output.line") == nil)
        #expect(parser.consume(line: "data: $ swift build") == nil)
        let frame = parser.consume(line: "")
        #expect(frame?.id == "42")
        #expect(frame?.event == "session.output.line")
        #expect(frame?.data == "$ swift build")
    }

    @Test("joins multi-line data with newlines")
    func joinsMultiLineData() {
        var parser = SSEParser()
        _ = parser.consume(line: "data: line one")
        _ = parser.consume(line: "data: line two")
        let frame = parser.consume(line: "")
        #expect(frame?.data == "line one\nline two")
    }

    @Test("ignores keepalive comments and blank frames")
    func ignoresComments() {
        var parser = SSEParser()
        #expect(parser.consume(line: ": keepalive") == nil)
        #expect(parser.consume(line: "") == nil)
    }

    @Test("defaults event name to message")
    func defaultsEventName() {
        var parser = SSEParser()
        _ = parser.consume(line: "data: hello")
        let frame = parser.consume(line: "")
        #expect(frame?.event == "message")
    }
}

@Suite("Centaur Client State")
@MainActor
struct CentaurClientStateTests {

    @Test("client reports connected immediately — REST has no transport handshake")
    func startsConnected() {
        let client = CentaurClient(
            baseURL: URL(string: "https://centaur.example.com")!,
            apiKey: "k"
        )
        // ChatViewModel.resumeSession guards on .connected BEFORE calling
        // resume; a .disconnected initial state deadlocks session selection.
        guard case .connected = client.connectionState else {
            Issue.record("expected .connected, got \(client.connectionState)")
            return
        }
    }
}

@Suite("Centaur Event Adapter")
struct CentaurEventAdapterTests {

    private func frame(event: String, data: String = "{}", id: String? = nil) -> SSEParser.Frame {
        SSEParser.Frame(id: id, event: event, data: data)
    }

    @Test("execution_started maps to messageStart")
    func startMapsToMessageStart() {
        var adapter = CentaurEventAdapter()
        let events = adapter.adapt(frame: frame(event: "session.execution_started"))
        #expect(events.count == 1)
        guard case .messageStart = events[0] else {
            Issue.record("expected messageStart, got \(events[0].debugName)")
            return
        }
    }

    @Test("plain-text output lines stream as messageDelta and accumulate")
    func plainTextLinesAccumulate() {
        var adapter = CentaurEventAdapter()
        _ = adapter.adapt(frame: frame(event: "session.execution_started"))
        let d1 = adapter.adapt(frame: frame(event: "session.output.line", data: "Checking tests..."))
        let d2 = adapter.adapt(frame: frame(event: "session.output.line", data: "All green."))

        guard case .messageDelta(let t1, _) = d1[0], case .messageDelta(let t2, _) = d2[0] else {
            Issue.record("expected messageDelta events")
            return
        }
        #expect(t1 == "Checking tests...\n")
        #expect(t2 == "All green.\n")

        let done = adapter.adapt(frame: frame(event: "session.execution_completed"))
        guard case .messageComplete(let payload) = done[0] else {
            Issue.record("expected messageComplete")
            return
        }
        #expect(payload.status == "complete")
        #expect(payload.text == "Checking tests...\nAll green.\n")
    }

    @Test("harness NDJSON: agent deltas stream, protocol noise is dropped, final text wins")
    func harnessFramesParse() {
        var adapter = CentaurEventAdapter()
        _ = adapter.adapt(frame: frame(event: "session.execution_started"))

        // Protocol frames that must NOT render as chat text
        let noise = [
            #"{"method":"thread/started","params":{"thread":{"id":"t1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"t1","turn":{"id":"turn-1"}}}"#,
            #"{"method":"item/started","params":{"item":{"id":"u1","type":"userMessage","content":[{"text":"hello","type":"text"}]}}}"#,
            #"{"method":"item/completed","params":{"item":{"id":"u1","type":"userMessage"}}}"#,
        ]
        for line in noise {
            #expect(adapter.adapt(frame: frame(event: "session.output.line", data: line)).isEmpty)
        }

        // Agent message deltas stream as messageDelta
        let d1 = adapter.adapt(frame: frame(
            event: "session.output.line",
            data: #"{"method":"item/agentMessage/delta","params":{"delta":"Hello! I'm Cent","itemId":"m1"}}"#
        ))
        guard case .messageDelta(let t1, _) = d1[0] else {
            Issue.record("expected messageDelta")
            return
        }
        #expect(t1 == "Hello! I'm Cent")

        _ = adapter.adapt(frame: frame(
            event: "session.output.line",
            data: #"{"method":"item/agentMessage/delta","params":{"delta":"aur.","itemId":"m1"}}"#
        ))

        // item/completed with authoritative final text
        _ = adapter.adapt(frame: frame(
            event: "session.output.line",
            data: #"{"method":"item/completed","params":{"item":{"id":"m1","type":"agentMessage","text":"Hello! I'm Centaur, the full text."}}}"#
        ))

        let done = adapter.adapt(frame: frame(event: "session.execution_completed"))
        guard case .messageComplete(let payload) = done[0] else {
            Issue.record("expected messageComplete")
            return
        }
        // Final text from item/completed wins over accumulated deltas.
        #expect(payload.text == "Hello! I'm Centaur, the full text.")
    }

    @Test("harness NDJSON: tool-ish items render as tool start/complete")
    func harnessToolItems() {
        var adapter = CentaurEventAdapter()
        let started = adapter.adapt(frame: frame(
            event: "session.output.line",
            data: #"{"method":"item/started","params":{"item":{"id":"tc1","type":"commandExecution","command":"swift build"}}}"#
        ))
        guard case .toolStart(let start) = started[0] else {
            Issue.record("expected toolStart")
            return
        }
        #expect(start.toolID == "tc1")
        #expect(start.name == "commandExecution")
        #expect(start.context == "swift build")

        let completed = adapter.adapt(frame: frame(
            event: "session.output.line",
            data: #"{"method":"item/completed","params":{"item":{"id":"tc1","type":"commandExecution","command":"swift build"}}}"#
        ))
        guard case .toolComplete(let done) = completed[0] else {
            Issue.record("expected toolComplete")
            return
        }
        #expect(done.toolID == "tc1")
    }

    @Test("harness NDJSON: error frames surface as error events")
    func harnessErrorFrames() {
        var adapter = CentaurEventAdapter()
        let events = adapter.adapt(frame: frame(
            event: "session.output.line",
            data: #"{"method":"error","params":{"error":{"message":"invalid blocks-mode input"}}}"#
        ))
        guard case .error(let message) = events[0] else {
            Issue.record("expected error event")
            return
        }
        #expect(message == "invalid blocks-mode input")
    }

    @Test("execution_failed maps to error-status completion plus error event")
    func failureMapsToError() {
        var adapter = CentaurEventAdapter()
        let events = adapter.adapt(frame: frame(
            event: "session.execution_failed",
            data: #"{"error": "sandbox OOM"}"#
        ))
        #expect(events.count == 2)
        guard case .messageComplete(let payload) = events[0],
              case .error(let message) = events[1] else {
            Issue.record("expected completion + error")
            return
        }
        #expect(payload.status == "error")
        #expect(message == "sandbox OOM")
    }

    @Test("execution_cancelled maps to interrupted completion")
    func cancelMapsToInterrupted() {
        var adapter = CentaurEventAdapter()
        let events = adapter.adapt(frame: frame(event: "session.execution_cancelled"))
        guard case .messageComplete(let payload) = events[0] else {
            Issue.record("expected messageComplete")
            return
        }
        #expect(payload.status == "interrupted")
    }

    @Test("hermes_event envelope tunnels typed events through Other passthrough")
    func tunnelsHermesEvents() {
        var adapter = CentaurEventAdapter()
        let data = #"{"hermes_event": {"type": "tool.start", "payload": {"tool_id": "t1", "name": "grep", "context": "pattern"}}}"#
        let events = adapter.adapt(frame: frame(event: "harness.custom", data: data))
        #expect(events.count == 1)
        guard case .toolStart(let payload) = events[0] else {
            Issue.record("expected toolStart, got \(events[0].debugName)")
            return
        }
        #expect(payload.name == "grep")
    }

    @Test("unknown events without envelope are dropped")
    func dropsUnknownEvents() {
        var adapter = CentaurEventAdapter()
        let events = adapter.adapt(frame: frame(event: "session.sandbox_assigned", data: "{}"))
        #expect(events.isEmpty)
    }
}

// MARK: - Workflow model decoding

@Suite("Centaur Workflow Models")
struct CentaurWorkflowModelTests {

    @Test("Run decodes the api-rs shape with RFC3339 timestamps")
    func runDecodes() throws {
        let json = """
        {"run_id": "wr_1", "task_id": "t_1", "workflow_name": "daily-digest",
         "status": "completed", "input": {"channel": "general"},
         "result": {"posted": true}, "failure": null, "attempts": 1,
         "created_at": "2026-07-19T09:00:00Z",
         "updated_at": "2026-07-19T09:00:05.123456Z"}
        """
        let run = try JSONDecoder().decode(CentaurWorkflowRun.self, from: Data(json.utf8))
        #expect(run.runID == "wr_1")
        #expect(run.workflowName == "daily-digest")
        #expect(!run.isActive)          // completed = terminal
        #expect(run.failureSummary == nil)
        #expect(run.createdAt != nil)
        #expect(run.updatedAt != nil)   // fractional seconds parse too
    }

    @Test("Active statuses and failure summaries")
    func activeAndFailure() throws {
        let json = """
        {"run_id": "wr_2", "task_id": "t", "workflow_name": "sync",
         "status": "running", "attempts": 3,
         "failure": {"message": "upstream 503"},
         "created_at": "2026-07-19T09:00:00Z", "updated_at": "2026-07-19T09:00:00Z"}
        """
        let run = try JSONDecoder().decode(CentaurWorkflowRun.self, from: Data(json.utf8))
        #expect(run.isActive)
        #expect(run.failureSummary == "upstream 503")
    }

    @Test("Schedule kind flattens cron and interval forms")
    func scheduleKinds() throws {
        // Upstream source shape: {"cron": {"expr": …}} / {"interval": {"secs": …}}.
        let cron = try JSONDecoder().decode(CentaurWorkflowSchedule.self, from: Data("""
        {"schedule_id": "s1", "workflow_name": "digest",
         "kind": {"cron": {"expr": "0 9 * * *"}}, "timezone": "America/New_York",
         "enabled": true}
        """.utf8))
        #expect(cron.kindLabel == "cron 0 9 * * *")
        #expect(cron.cronExpression == "0 9 * * *")
        #expect(cron.enabled)

        let interval = try JSONDecoder().decode(CentaurWorkflowSchedule.self, from: Data("""
        {"schedule_id": "s2", "workflow_name": "sync",
         "kind": {"interval": {"secs": 3600}}, "enabled": false}
        """.utf8))
        #expect(interval.kindLabel.hasPrefix("every "))
        #expect(interval.intervalSeconds == 3600)
        #expect(!interval.enabled)

        // Live deployment shape (verified against slackbot.darkbloom.ai):
        // {"type": "interval", "interval_seconds": N} / {"type": "cron", "cron": "expr"}.
        let liveInterval = try JSONDecoder().decode(CentaurWorkflowSchedule.self, from: Data("""
        {"schedule_id": "s3", "workflow_name": "postcall_watcher",
         "kind": {"interval_seconds": 300, "type": "interval"},
         "timezone": "America/Los_Angeles", "enabled": true}
        """.utf8))
        #expect(liveInterval.intervalSeconds == 300)
        #expect(liveInterval.kindLabel == "every 5m")

        let liveCron = try JSONDecoder().decode(CentaurWorkflowSchedule.self, from: Data("""
        {"schedule_id": "s4", "workflow_name": "standup_digest",
         "kind": {"cron": "0 9 * * 1-5", "type": "cron"},
         "timezone": "America/Los_Angeles", "enabled": true}
        """.utf8))
        #expect(liveCron.cronExpression == "0 9 * * 1-5")
        #expect(liveCron.kindLabel == "cron 0 9 * * 1-5")
    }
}
