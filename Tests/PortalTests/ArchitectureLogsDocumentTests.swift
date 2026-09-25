import Testing
import Foundation
@testable import Portal

@Suite("Architecture logs — architecture.logs / follow wire shapes")
internal struct ArchitectureLogsDocumentTests {
    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    @Test("a sink decodes every field, labels its kind and size, and skips malformed entries")
    internal func sinkDecoding() throws {
        let value = try decode("""
        [
          {"id": "stdout", "kind": "launchd_stdout", "label": "launchd stdout", "path": "/tmp/portal.out.log",
           "exists": true, "size_bytes": 1536, "modified_at": "2026-09-26T01:00:00+00:00"},
          {"id": "dir", "kind": "directory", "path": "/tmp/logs", "exists": false},
          {"kind": "file"},
          "not a sink"
        ]
        """)
        let sinks = ArchitectureLogSink.decodeList(value)
        #expect(sinks.count == 2)
        #expect(sinks[0].kindLabel == "launchd stdout")
        #expect(sinks[0].sizeLabel == "1.5 KB")
        #expect(sinks[0].displayLabel == "launchd stdout")
        #expect(sinks[0].modifiedAt.hasPrefix("2026-09-26"))
        #expect(sinks[1].kindLabel == "Directory")
        #expect(sinks[1].sizeLabel == "missing")
        #expect(sinks[1].displayLabel == "dir", "no label falls back to the id")
        #expect(sinks[1].label.isEmpty)
        #expect(ArchitectureLogSink.decodeList(nil).isEmpty)
        #expect(ArchitectureLogSink(id: "x", kind: "custom", label: "", path: "", exists: true, sizeBytes: 0, modifiedAt: "").kindLabel == "custom")
    }

    @Test("byte sizes format in the nearest unit")
    internal func byteFormatting() {
        #expect(ArchitectureLogSink.formatBytes(0) == "0 B")
        #expect(ArchitectureLogSink.formatBytes(999) == "999 B")
        #expect(ArchitectureLogSink.formatBytes(1024) == "1.0 KB")
        #expect(ArchitectureLogSink.formatBytes(5 * 1024 * 1024) == "5.0 MB")
        #expect(ArchitectureLogSink.formatBytes(3 * 1024 * 1024 * 1024) == "3.0 GB")
        #expect(ArchitectureLogSink.formatBytes(-5) == "0 B")
    }

    @Test("a tail decodes lines, cursor, truncation and rotation; missing lines is an invalid response")
    internal func tailDecoding() throws {
        let tail = try ArchitectureLogTail.decodeGatewayValue(try decode("""
        {"service": "arch:portal", "sink": {"id": "stdout", "kind": "file", "path": "/tmp/a.log", "exists": true, "size_bytes": 10},
         "sinks": [{"id": "stdout", "kind": "file", "path": "/tmp/a.log", "exists": true}],
         "lines": ["one", "two", 3], "cursor": "4096", "truncated": true, "rotated": true, "encoding": "utf-8-replace"}
        """))
        #expect(tail.service == "arch:portal")
        #expect(tail.sink?.id == "stdout")
        #expect(tail.sinks.count == 1)
        #expect(tail.lines == ["one", "two"], "non-string entries are dropped")
        #expect(tail.cursor == "4096")
        #expect(tail.truncated)
        #expect(tail.rotated)
        #expect(tail.encoding == "utf-8-replace")
        let minimal = try ArchitectureLogTail.decodeGatewayValue(try decode("{\"lines\": []}"))
        #expect(minimal.lines.isEmpty)
        #expect(!minimal.truncated)
        #expect(!minimal.rotated)
        #expect(minimal.encoding == "utf-8-replace")
        #expect(throws: GatewayError.self) {
            _ = try ArchitectureLogTail.decodeGatewayValue(try decode("{\"cursor\": \"1\"}"))
        }
    }

    @Test("follow state decodes; the event payload decodes lines, rotation and the stop reason")
    internal func followAndEvent() throws {
        let state = try ArchitectureLogFollowState.decodeGatewayValue(try decode("""
        {"following": true, "sink": {"id": "s", "kind": "file", "path": "/p", "exists": true}, "cursor": "12"}
        """))
        #expect(state.following)
        #expect(state.sink?.id == "s")
        #expect(state.cursor == "12")
        #expect(throws: GatewayError.self) {
            _ = try ArchitectureLogFollowState.decodeGatewayValue(try decode("{\"sink\": null}"))
        }
        let payload = try decode("""
        {"service": "arch:portal", "sink": "s", "lines": ["a", "b"], "cursor": "20", "rotated": true, "stopped": "idle-timeout"}
        """).dictionaryValue ?? [:]
        let event = ArchitectureLogEvent.decodePayload(payload)
        #expect(event.service == "arch:portal")
        #expect(event.sink == "s")
        #expect(event.lines == ["a", "b"])
        #expect(event.cursor == "20")
        #expect(event.rotated)
        #expect(event.stopped == "idle-timeout")
        let bare = ArchitectureLogEvent.decodePayload([:])
        #expect(bare.lines.isEmpty)
        #expect(!bare.rotated)
        #expect(bare.stopped == nil)
        // The gateway event enum routes the wire type to the typed payload.
        if case .architectureLog(let decoded) = GatewayEvent.from(type: "architecture.log", payload: .dictionary(payload)) {
            #expect(decoded == event)
        } else {
            Issue.record("architecture.log did not decode to .architectureLog")
        }
        #expect(GatewayEvent.architectureLog(event).debugName == "architecture.log")
    }

    @Test("the service ref carries its declared sinks and the document its is_latest flag")
    internal func serviceLogsAndIsLatest() throws {
        let value = try decode("""
        {"service": {"id": "arch:portal", "label": "Portal", "description": "", "source": "local", "root": "/x",
                     "model_path": "m.json", "check_configured": true,
                     "logs": [{"id": "out", "kind": "file", "path": "/x/portal.log", "exists": true, "size_bytes": 2}]},
         "revision": "abc", "source": "local", "is_latest": false,
         "model": {"schema_version": "1.0.0"}}
        """)
        let document = try ArchitectureModelDocument.decodeGatewayValue(value)
        #expect(document.service.logs.map(\.id) == ["out"])
        #expect(!document.isLatest)
        let older = try decode("""
        {"service": {"id": "arch:portal", "label": "Portal", "description": "", "source": "local", "model_path": "m.json", "check_configured": false},
         "revision": "abc", "source": "local", "model": {"schema_version": "1.0.0"}}
        """)
        let legacy = try ArchitectureModelDocument.decodeGatewayValue(older)
        #expect(legacy.service.logs.isEmpty)
        #expect(legacy.isLatest, "an older gateway without is_latest is the latest")
        #expect(legacy != document)
    }
}
