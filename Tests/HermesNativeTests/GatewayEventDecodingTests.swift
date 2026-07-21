import Testing
import Foundation
@testable import HermesNative

@Suite("Gateway Event Decoding — new families")
struct GatewayEventDecodingTests {

    // MARK: - tool.output_risk

    @Test("tool.output_risk parses full payload")
    func toolOutputRiskFullPayload() {
        let payload = AnyCodable.dictionary([
            "tool_id": .string("tool-42"),
            "name": .string("terminal"),
            "risk": .string("high"),
            "findings": .array([.string("credential in output"), .string("private key material")]),
            "redacted": .bool(true),
        ])
        let event = GatewayEvent.from(type: "tool.output_risk", payload: payload)
        guard case .toolOutputRisk(let risk) = event else {
            Issue.record("expected toolOutputRisk, got \(event.debugName)")
            return
        }
        #expect(risk.toolID == "tool-42")
        #expect(risk.name == "terminal")
        #expect(risk.risk == .high)
        #expect(risk.findings == ["credential in output", "private key material"])
        #expect(risk.redacted == true)
    }

    @Test("tool.output_risk defaults missing fields safely")
    func toolOutputRiskDefaults() {
        let event = GatewayEvent.from(type: "tool.output_risk", payload: .dictionary([
            "tool_id": .string("tool-1"),
        ]))
        guard case .toolOutputRisk(let risk) = event else {
            Issue.record("expected toolOutputRisk, got \(event.debugName)")
            return
        }
        #expect(risk.risk == .low)
        #expect(risk.findings.isEmpty)
        #expect(risk.redacted == false)
    }

    @Test("tool.output_risk unknown risk string falls back to low")
    func toolOutputRiskUnknownLevel() {
        let event = GatewayEvent.from(type: "tool.output_risk", payload: .dictionary([
            "tool_id": .string("tool-1"),
            "risk": .string("catastrophic"),
        ]))
        guard case .toolOutputRisk(let risk) = event else {
            Issue.record("expected toolOutputRisk, got \(event.debugName)")
            return
        }
        #expect(risk.risk == .low)
    }

    // MARK: - moa.*

    @Test("moa.reference parses label, text, and count")
    func moaReferenceFullPayload() {
        let event = GatewayEvent.from(type: "moa.reference", payload: .dictionary([
            "label": .string("slot-2 (gpt-4o)"),
            "text": .string("Reference answer body"),
            "count": .int(3),
        ]))
        guard case .moaReference(let label, let text, let count) = event else {
            Issue.record("expected moaReference, got \(event.debugName)")
            return
        }
        #expect(label == "slot-2 (gpt-4o)")
        #expect(text == "Reference answer body")
        #expect(count == 3)
    }

    @Test("moa.reference falls back to preview when text is missing")
    func moaReferencePreviewFallback() {
        let event = GatewayEvent.from(type: "moa.reference", payload: .dictionary([
            "label": .string("slot-1"),
            "preview": .string("Preview body"),
        ]))
        guard case .moaReference(let label, let text, let count) = event else {
            Issue.record("expected moaReference, got \(event.debugName)")
            return
        }
        #expect(label == "slot-1")
        #expect(text == "Preview body")
        #expect(count == nil)
    }

    @Test("moa.aggregating parses the aggregator name")
    func moaAggregating() {
        let event = GatewayEvent.from(type: "moa.aggregating", payload: .dictionary([
            "aggregator": .string("claude-opus"),
        ]))
        guard case .moaAggregating(let aggregator) = event else {
            Issue.record("expected moaAggregating, got \(event.debugName)")
            return
        }
        #expect(aggregator == "claude-opus")
    }

    @Test("moa.aggregating with empty payload defaults to empty aggregator")
    func moaAggregatingEmpty() {
        let event = GatewayEvent.from(type: "moa.aggregating", payload: nil)
        guard case .moaAggregating(let aggregator) = event else {
            Issue.record("expected moaAggregating, got \(event.debugName)")
            return
        }
        #expect(aggregator.isEmpty)
    }

    // MARK: - browser/preview progress → statusUpdate

    @Test("browser.progress folds into statusUpdate(kind: browser)")
    func browserProgress() {
        let event = GatewayEvent.from(type: "browser.progress", payload: .dictionary([
            "message": .string("navigating to page"),
            "level": .string("info"),
        ]))
        guard case .statusUpdate(let kind, let text) = event else {
            Issue.record("expected statusUpdate, got \(event.debugName)")
            return
        }
        #expect(kind == "browser")
        #expect(text == "navigating to page")
    }

    @Test("preview.restart.progress folds into statusUpdate(kind: preview)")
    func previewRestartProgress() {
        let event = GatewayEvent.from(type: "preview.restart.progress", payload: .dictionary([
            "task_id": .string("t1"),
            "level": .string("info"),
            "text": .string("restarting preview server"),
        ]))
        guard case .statusUpdate(let kind, let text) = event else {
            Issue.record("expected statusUpdate, got \(event.debugName)")
            return
        }
        #expect(kind == "preview")
        #expect(text == "restarting preview server")
    }

    @Test("preview.restart.complete uses the text as-is")
    func previewRestartComplete() {
        let event = GatewayEvent.from(type: "preview.restart.complete", payload: .dictionary([
            "task_id": .string("t1"),
            "text": .string("preview restarted"),
        ]))
        guard case .statusUpdate(let kind, let text) = event else {
            Issue.record("expected statusUpdate, got \(event.debugName)")
            return
        }
        #expect(kind == "preview")
        #expect(text == "preview restarted")
    }

    // MARK: - reaction

    @Test("reaction parses the kind")
    func reactionKind() {
        let event = GatewayEvent.from(type: "reaction", payload: .dictionary([
            "kind": .string("hearts"),
        ]))
        guard case .reaction(let kind) = event else {
            Issue.record("expected reaction, got \(event.debugName)")
            return
        }
        #expect(kind == "hearts")
    }

    @Test("reaction with missing kind decodes to empty string")
    func reactionMissingKind() {
        let event = GatewayEvent.from(type: "reaction", payload: nil)
        guard case .reaction(let kind) = event else {
            Issue.record("expected reaction, got \(event.debugName)")
            return
        }
        #expect(kind.isEmpty)
    }

    // MARK: - forward tolerance unchanged

    @Test("unrecognized types still decode to .unknown")
    func unknownStillTolerated() {
        let event = GatewayEvent.from(type: "pet.feed", payload: nil)
        guard case .unknown(let type) = event else {
            Issue.record("expected unknown, got \(event.debugName)")
            return
        }
        #expect(type == "pet.feed")
    }
}

// MARK: - ToolCallRecord risk update

@Suite("ToolCallRecord risk update")
struct ToolCallRecordRiskTests {

    @Test("applyRisk sets level, findings, and redacted marker")
    func applyRiskSetsFields() {
        var record = ToolCallRecord(id: "tool-1", name: "terminal")
        record.applyRisk(ToolOutputRiskPayload(
            toolID: "tool-1",
            name: "terminal",
            risk: .medium,
            findings: ["suspicious URL"],
            redacted: true
        ))
        #expect(record.riskLevel == .medium)
        #expect(record.riskFindings == ["suspicious URL"])
        #expect(record.riskRedacted == true)
    }

    @Test("applyRisk normalizes empty findings and non-redacted to nil")
    func applyRiskNormalizesEmpties() {
        var record = ToolCallRecord(id: "tool-1", name: "terminal")
        record.applyRisk(ToolOutputRiskPayload(
            toolID: "tool-1",
            name: "terminal",
            risk: .low,
            findings: [],
            redacted: false
        ))
        #expect(record.riskLevel == .low)
        #expect(record.riskFindings == nil)
        #expect(record.riskRedacted == nil)
    }

    @Test("risk metadata round-trips through Codable and old JSON still decodes")
    func riskCodableRoundTrip() throws {
        var record = ToolCallRecord(id: "tool-1", name: "browser", isComplete: true)
        record.applyRisk(ToolOutputRiskPayload(
            toolID: "tool-1", name: "browser", risk: .high,
            findings: ["exfil attempt"], redacted: true
        ))
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ToolCallRecord.self, from: data)
        #expect(decoded.riskLevel == .high)
        #expect(decoded.riskFindings == ["exfil attempt"])
        #expect(decoded.riskRedacted == true)

        // Persisted records that predate risk metadata decode with nils.
        let legacy = Data(#"{"id":"t0","name":"terminal","isComplete":true}"#.utf8)
        let old = try JSONDecoder().decode(ToolCallRecord.self, from: legacy)
        #expect(old.riskLevel == nil)
        #expect(old.riskFindings == nil)
    }
}

// MARK: - ChatViewModel event application

@Suite("ChatViewModel new-event application")
struct ChatViewModelNewEventTests {

    @Test("tool.output_risk badges an active tool call")
    @MainActor
    func riskBadgesActiveTool() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "s1")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "s1")
        vm.receiveGatewayEventForTesting(.toolStart(payload: ToolStartPayload(
            toolID: "tool-1", name: "terminal", context: "curl example.com"
        )), sessionID: "s1")

        vm.receiveGatewayEventForTesting(.toolOutputRisk(payload: ToolOutputRiskPayload(
            toolID: "tool-1", name: "terminal", risk: .high,
            findings: ["credential leak"], redacted: true
        )), sessionID: "s1")

        #expect(vm.activeToolCalls["tool-1"]?.riskLevel == .high)
        #expect(vm.activeToolCalls["tool-1"]?.riskFindings == ["credential leak"])
        #expect(vm.activeToolCalls["tool-1"]?.riskRedacted == true)
    }

    @Test("tool.output_risk arriving after messageComplete badges the merged record")
    @MainActor
    func riskBadgesMergedTool() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "s1")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "s1")
        vm.receiveGatewayEventForTesting(.toolStart(payload: ToolStartPayload(
            toolID: "tool-1", name: "terminal", context: "ls"
        )), sessionID: "s1")
        vm.receiveGatewayEventForTesting(.messageComplete(payload: MessageCompletePayload(
            text: "done", status: "complete", usage: nil, reasoning: nil, rendered: nil, warning: nil
        )), sessionID: "s1")
        #expect(vm.isStreaming == false)

        vm.receiveGatewayEventForTesting(.toolOutputRisk(payload: ToolOutputRiskPayload(
            toolID: "tool-1", name: "terminal", risk: .medium,
            findings: ["odd output"], redacted: false
        )), sessionID: "s1")

        let merged = vm.messages.last?.toolCalls.first { $0.id == "tool-1" }
        #expect(merged?.riskLevel == .medium)
        #expect(merged?.riskFindings == ["odd output"])
    }

    @Test("moa.reference lands as a discrete labelled thinking block")
    @MainActor
    func moaReferenceLandsAsLabelledBlock() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "s1")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "s1")

        vm.receiveGatewayEventForTesting(
            .moaReference(label: "slot-1 (gpt-4o)", text: "First reference", count: nil),
            sessionID: "s1"
        )
        vm.receiveGatewayEventForTesting(
            .moaReference(label: "slot-2 (llama)", text: "Second reference", count: nil),
            sessionID: "s1"
        )

        let trace = vm.messages.last?.thinkingTrace
        #expect(trace?.blocks.count == 2)
        #expect(trace?.blocks.first?.kind == .moaReference)
        #expect(trace?.blocks.first?.label == "slot-1 (gpt-4o)")
        #expect(trace?.blocks.first?.text == "First reference")
        #expect(trace?.blocks.last?.label == "slot-2 (llama)")
    }

    @Test("moa.aggregating sets the transient status line")
    @MainActor
    func moaAggregatingSetsStatus() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "s1")
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: "s1")
        vm.receiveGatewayEventForTesting(.moaAggregating(aggregator: "claude-opus"), sessionID: "s1")
        #expect(vm.transientStatus == "aggregating via claude-opus")
    }

    @Test("statusUpdate (browser/preview progress) sets the transient status line")
    @MainActor
    func statusUpdateSetsStatus() async {
        let vm = ChatViewModel()
        _ = vm.beginSwitchToSession(key: "s1")
        vm.receiveGatewayEventForTesting(.statusUpdate(kind: "browser", text: "navigating"), sessionID: "s1")
        #expect(vm.transientStatus == "navigating")
    }
}
