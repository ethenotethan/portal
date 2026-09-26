import Testing
import Foundation
@testable import Portal

@MainActor
@Suite("Architecture logs model — tail, cursor, follow, filter")
internal struct ArchitectureLogsModelTests {
    private func sink(_ id: String, exists: Bool = true) -> ArchitectureLogSink {
        ArchitectureLogSink(id: id, kind: "file", label: id.uppercased(), path: "/tmp/\(id).log", exists: exists, sizeBytes: 12, modifiedAt: "t")
    }

    private func tail(_ lines: [String], cursor: String, sinks: [ArchitectureLogSink] = [], truncated: Bool = false, rotated: Bool = false) -> ArchitectureLogTail {
        ArchitectureLogTail(service: "arch:portal", sink: sinks.first, sinks: sinks, lines: lines, cursor: cursor,
                            truncated: truncated, rotated: rotated, encoding: "utf-8-replace")
    }

    @Test("load reads the tail of the first sink; fetchMore continues from the cursor and appends")
    internal func loadThenFetchMore() async {
        let reader = ArchitectureLogsRevisionsStub()
        reader.tails = [tail(["a", "b"], cursor: "10", sinks: [sink("out"), sink("err")], truncated: true), tail(["c"], cursor: "14")]
        let model = ArchitectureLogsModel(service: "arch:portal", sinks: [sink("out")], reader: reader)
        #expect(model.selectedSinkID == "out")
        await model.load()
        #expect(model.lines == ["a", "b"])
        #expect(model.cursor == "10")
        #expect(model.truncated)
        #expect(model.sinks.map(\.id) == ["out", "err"], "the gateway's resolved sinks replace the manifest list")
        #expect(reader.logCalls.first?.cursor == nil)
        #expect(reader.logCalls.first?.lines == ArchitectureLogsModel.tailLines)
        await model.fetchMore()
        #expect(model.lines == ["a", "b", "c"])
        #expect(model.cursor == "14")
        #expect(!model.truncated)
        #expect(reader.logCalls.last?.cursor == "10")
        #expect(model.errorMessage == nil)
        #expect(!model.isLoading)
    }

    @Test("a rotated tail on fetchMore restarts the buffer; without a cursor fetchMore loads the tail")
    internal func rotationAndNoCursor() async {
        let reader = ArchitectureLogsRevisionsStub()
        reader.tails = [tail(["old"], cursor: "5"), tail(["fresh"], cursor: "2", rotated: true)]
        let model = ArchitectureLogsModel(service: "arch:portal", sinks: [sink("out")], reader: reader)
        await model.fetchMore()
        #expect(model.lines == ["old"], "no cursor yet: fetchMore behaves as load")
        await model.fetchMore()
        #expect(model.lines == ["fresh"])
        #expect(model.statusMessage == "Log rotated · tail restarted")
    }

    @Test("gateway errors surface verbatim; a service without sinks says so without calling the gateway")
    internal func errors() async {
        let reader = ArchitectureLogsRevisionsStub()
        reader.tailError = GatewayError.rpcError(JSONRPCError(code: 4041, message: "sink 'out' does not exist: /tmp/out.log"))
        let model = ArchitectureLogsModel(service: "arch:portal", sinks: [sink("out", exists: false)], reader: reader)
        await model.load()
        #expect(model.errorMessage == "sink 'out' does not exist: /tmp/out.log")
        #expect(model.lines.isEmpty)
        let none = ArchitectureLogsModel(service: "arch:portal", sinks: [], reader: reader)
        await none.load()
        #expect(none.errorMessage == "This service declares no log sink.")
        #expect(reader.logCalls.count == 1)
    }

    @Test("following appends event lines for the selected sink only, restarts on rotation, and stops when the gateway says so")
    internal func followEvents() async {
        let reader = ArchitectureLogsRevisionsStub()
        reader.tails = [tail(["a"], cursor: "1")]
        reader.followStates = [ArchitectureLogFollowState(following: true, sink: sink("out"), cursor: "1")]
        let model = ArchitectureLogsModel(service: "arch:portal", sinks: [sink("out"), sink("err")], reader: reader)
        await model.load()
        await model.toggleFollow()
        #expect(model.isFollowing)
        #expect(model.statusMessage == "Following OUT")
        #expect(reader.followCalls.last?.enabled == true)
        reader.events.send(.serviceLog(ArchitectureLogEvent(service: "arch:portal", sink: "out", lines: ["b", "c"], cursor: "3", rotated: false, stopped: nil)))
        #expect(model.lines == ["a", "b", "c"])
        #expect(model.cursor == "3")
        reader.events.send(.serviceLog(ArchitectureLogEvent(service: "arch:portal", sink: "err", lines: ["ignored"], cursor: "9", rotated: false, stopped: nil)))
        reader.events.send(.serviceLog(ArchitectureLogEvent(service: "arch:other", sink: "out", lines: ["ignored"], cursor: "9", rotated: false, stopped: nil)))
        #expect(model.lines == ["a", "b", "c"], "other sinks and services are ignored")
        reader.events.send(.serviceLog(ArchitectureLogEvent(service: "arch:portal", sink: "out", lines: ["z"], cursor: "1", rotated: true, stopped: nil)))
        #expect(model.lines == ["z"])
        #expect(model.statusMessage == "Log rotated · tail restarted")
        reader.events.send(.serviceLog(ArchitectureLogEvent(service: "arch:portal", sink: "out", lines: [], cursor: "1", rotated: false, stopped: "idle-timeout")))
        #expect(!model.isFollowing)
        #expect(model.statusMessage == "Follow stopped after ten idle minutes")
        reader.events.send(.architectureChanged(service: "arch:portal", revision: "r", reason: "snapshot", status: ""))
        #expect(model.lines == ["z"], "unrelated events are ignored")
    }

    @Test("switching sinks stops the follow, clears the buffer and loads the new tail; teardown stops the follow")
    internal func switchingAndTeardown() async {
        let reader = ArchitectureLogsRevisionsStub()
        reader.tails = [tail(["out-1"], cursor: "1"), tail(["err-1"], cursor: "7")]
        let model = ArchitectureLogsModel(service: "arch:portal", sinks: [sink("out"), sink("err")], reader: reader)
        await model.load()
        await model.setFollowing(true)
        #expect(model.isFollowing)
        await model.select(sinkID: "err")
        #expect(model.selectedSinkID == "err")
        #expect(!model.isFollowing)
        #expect(model.lines == ["err-1"])
        #expect(model.cursor == "7")
        #expect(reader.followCalls.map(\.enabled) == [true, false])
        await model.select(sinkID: "err")
        await model.select(sinkID: "missing")
        #expect(reader.logCalls.count == 2, "re-selecting or selecting an unknown sink does nothing")
        await model.setFollowing(true)
        await model.teardown()
        #expect(!model.isFollowing)
        #expect(reader.followCalls.last?.enabled == false)
        reader.followError = GatewayError.rpcError(JSONRPCError(code: 4040, message: "unknown sink"))
        await model.setFollowing(true)
        #expect(!model.isFollowing)
        #expect(model.errorMessage == "unknown sink")
    }

    @Test("the filter narrows the buffer case-insensitively and the buffer is bounded")
    internal func filterAndBound() async {
        let reader = ArchitectureLogsRevisionsStub()
        reader.tails = [tail(["Error: disk", "info: ok", "ERROR again"], cursor: "1")]
        let model = ArchitectureLogsModel(service: "arch:portal", sinks: [sink("out")], reader: reader)
        await model.load()
        model.filter = "  error "
        #expect(model.filteredLines == ["Error: disk", "ERROR again"])
        model.filter = ""
        #expect(model.filteredLines.count == 3)
        let flood = (0..<(ArchitectureLogsModel.maxBufferedLines + 10)).map { "line \($0)" }
        model.handle(ArchitectureLogEvent(service: "arch:portal", sink: "out", lines: flood, cursor: "x", rotated: false, stopped: nil))
        #expect(model.lines.count == ArchitectureLogsModel.maxBufferedLines)
        #expect(model.lines.last == "line \(ArchitectureLogsModel.maxBufferedLines + 9)")
        #expect(model.lines.first == "line 10", "the three tail lines and the oldest flood lines fall off")
    }
}
