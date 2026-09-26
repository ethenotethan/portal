import Testing
import Foundation
@testable import Portal

/// A scripted unified log: batches handed out in order, or a thrown error.
private final class ScriptedLogReader: UnifiedLogReading, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[UnifiedLogLine]]
    private var failures: Int
    private(set) var calls: [Date?] = []
    private(set) var sawMainThread = false

    init(batches: [[UnifiedLogLine]], failures: Int = 0) {
        self.batches = batches
        self.failures = failures
    }

    func entries(after: Date?) throws -> [UnifiedLogLine] {
        lock.lock()
        defer { lock.unlock() }
        calls.append(after)
        if Thread.isMainThread { sawMainThread = true }
        if failures > 0 {
            failures -= 1
            throw CocoaError(.fileReadUnknown)
        }
        guard !batches.isEmpty else { return [] }
        return batches.removeFirst()
    }
}

/// A primary that yields nothing and a fallback that yields, switched on request.
private final class SwitchableFakeReader: UnifiedLogFallbackSwitching, @unchecked Sendable {
    private let lock = NSLock()
    private var switched = false
    private(set) var reasons: [String] = []
    private var fallbackBatches: [[UnifiedLogLine]]

    init(fallbackBatches: [[UnifiedLogLine]]) {
        self.fallbackBatches = fallbackBatches
    }

    var name: String { isSwitched ? "Fallback" : "Primary" }

    var isSwitched: Bool {
        lock.lock()
        defer { lock.unlock() }
        return switched
    }

    func switchToFallback(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        switched = true
        reasons.append(reason)
    }

    func entries(after: Date?) throws -> [UnifiedLogLine] {
        lock.lock()
        defer { lock.unlock() }
        guard switched, !fallbackBatches.isEmpty else { return [] }
        return fallbackBatches.removeFirst()
    }
}

@Suite("Unified log mirror — Portal's declared log sink")
internal struct UnifiedLogMirrorTests {
    private static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func line(_ seconds: TimeInterval, _ message: String, level: String = "info", category: String = "Test") -> UnifiedLogLine {
        UnifiedLogLine(date: Self.epoch.addingTimeInterval(seconds), level: level, category: category, message: message)
    }

    private func temporaryLog() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("portal-log-mirror-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("Logs/Portal/portal.log", isDirectory: false)
    }

    // MARK: Pure helpers

    @Test("the default sink is Library/Logs/Portal/portal.log")
    internal func defaultPath() {
        let url = UnifiedLogMirror.defaultLogURL()
        #expect(url.lastPathComponent == "portal.log")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Portal")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Logs")
        #expect(url.pathComponents.contains("Library"))
        #expect(url.isFileURL)
    }

    @Test("an entry formats as one ISO8601 line with the level and category, newlines escaped")
    internal func formatting() {
        let formatted = UnifiedLogMirror.formatEntry(line(0.5, "first\nsecond\r\nthird\rfourth", level: "error", category: "GatewayClient"))
        #expect(formatted == "2026-09-21T14:13:20.500Z [error] GatewayClient: first\\nsecond\\nthird\\nfourth")
        #expect(!formatted.contains("\n"))
    }

    // MARK: Appender

    @Test("appending creates the directory, keeps one line per entry and reports the size")
    internal func appendCreatesAndGrows() throws {
        let url = try temporaryLog()
        let appender = LogFileAppender(fileURL: url)
        #expect(appender.currentSize() == 0)
        let first = try appender.append(["a", "b"])
        #expect(first == 4)
        let second = try appender.append(["c"])
        #expect(second == 6)
        #expect(try appender.append([]) == 6, "nothing to write leaves the file alone")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "a\nb\nc\n")
    }

    @Test("the file rotates once past the threshold and the previous generation is replaced, not stacked")
    internal func rotation() throws {
        let url = try temporaryLog()
        let appender = LogFileAppender(fileURL: url, rotationThresholdBytes: 10)
        try appender.append(["0123456789ab"]) // 13 bytes: over the threshold, but rotation happens on the next append
        #expect(!FileManager.default.fileExists(atPath: appender.rotatedURL.path))
        try appender.append(["second"])
        #expect(try String(contentsOf: appender.rotatedURL, encoding: .utf8) == "0123456789ab\n")
        #expect(try String(contentsOf: url, encoding: .utf8) == "second\n")
        try appender.append(["0123456789cd"])
        try appender.append(["third"])
        #expect(try String(contentsOf: appender.rotatedURL, encoding: .utf8) == "second\n0123456789cd\n", "only one previous generation is kept")
        #expect(try String(contentsOf: url, encoding: .utf8) == "third\n")
    }

    // MARK: Mirror

    @Test("a flush writes the new entries and the next read starts after the newest one")
    internal func flushAdvances() async throws {
        let url = try temporaryLog()
        let reader = ScriptedLogReader(batches: [[line(1, "one"), line(2, "two")], [line(3, "three")]])
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url))
        await mirror.flush()
        await mirror.flush()
        await mirror.flush() // nothing new
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.components(separatedBy: "\n").filter { !$0.isEmpty }.count == 3)
        #expect(text.contains("[info] Test: one"))
        #expect(text.contains("Test: three"))
        #expect(await mirror.linesWritten == 3)
        #expect(reader.calls == [nil, Self.epoch.addingTimeInterval(2), Self.epoch.addingTimeInterval(3)])
        #expect(!reader.sawMainThread, "the reader is driven from the mirror actor, never the main thread")
    }

    @Test("entries the store re-delivers at the boundary timestamp are not written twice, and new ones at that timestamp are")
    internal func boundaryDeduplication() async throws {
        let url = try temporaryLog()
        let reader = ScriptedLogReader(batches: [
            [line(1, "a"), line(2, "b")],
            [line(2, "b"), line(2, "b-again"), line(3, "c")],
        ])
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url))
        await mirror.flush()
        await mirror.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.map { $0.components(separatedBy: "Test: ").last ?? "" } == ["a", "b", "b-again", "c"])
    }

    @Test("a reader failure is counted once, the mirror backs off with doubling waits, then resumes")
    internal func backoffAndRecovery() async throws {
        let url = try temporaryLog()
        let reader = ScriptedLogReader(batches: [[line(1, "after recovery")]], failures: 2)
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url))
        await mirror.flush() // fails: back off 1 cycle
        #expect(await mirror.readErrorCount == 1)
        #expect(await mirror.isBackingOff)
        await mirror.flush() // skipped
        #expect(reader.calls.count == 1)
        await mirror.flush() // fails again: back off 2 cycles
        #expect(await mirror.readErrorCount == 2)
        await mirror.flush()
        await mirror.flush()
        #expect(reader.calls.count == 2, "two cycles skipped")
        await mirror.flush() // reads the batch
        #expect(!(await mirror.isBackingOff))
        #expect(await mirror.linesWritten == 1)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("after recovery"))
    }

    @Test("a write failure is counted and backed off without losing the position")
    internal func writeFailure() async throws {
        let url = try temporaryLog()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A directory where the file should be makes every append fail.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let reader = ScriptedLogReader(batches: [[line(1, "x")], [line(2, "y")]])
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url))
        await mirror.flush()
        #expect(await mirror.writeErrorCount == 1)
        #expect(await mirror.linesWritten == 0)
        #expect(reader.calls == [nil], "the position did not advance past the unwritten entries")
    }

    @Test("start polls on its cadence and stop ends the loop; starting twice is one loop")
    internal func startAndStop() async throws {
        let url = try temporaryLog()
        let reader = ScriptedLogReader(batches: [[line(1, "tick")], [line(2, "tock")]])
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url), cadence: .milliseconds(20))
        await mirror.start(appVersion: "test")
        await mirror.start(appVersion: "test")
        try await Task.sleep(for: .milliseconds(200))
        await mirror.stop()
        let written = await mirror.linesWritten
        #expect(written == 2)
        let callsAfterStop = reader.calls.count
        try await Task.sleep(for: .milliseconds(80))
        #expect(reader.calls.count == callsAfterStop, "no polling after stop")
        #expect(await mirror.fileURL == url)
    }

    @Test("start writes the startup line to the file directly and the first read is anchored at the launch date")
    internal func startupLineAndAnchor() async throws {
        let url = try temporaryLog()
        let anchor = Self.epoch
        let reader = ScriptedLogReader(batches: [[line(1, "after launch")]])
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url), cadence: .seconds(60), since: anchor)
        await mirror.start(appVersion: "9.9")
        // The direct line exists before any read has completed.
        let immediately = try String(contentsOf: url, encoding: .utf8)
        let expectedStartup = "[notice] UnifiedLogMirror: Portal 9.9 started; reader=ScriptedLogReader; "
            + "pid=\(ProcessInfo.processInfo.processIdentifier); since=2026-09-21T14:13:20.000Z"
        #expect(immediately.contains(expectedStartup))
        try await Task.sleep(for: .milliseconds(150))
        await mirror.stop()
        #expect(reader.calls.first == anchor, "the first read asks for everything since launch, so the startup notice logged during start is captured")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        #expect(lines[0].contains("UnifiedLogMirror: Portal 9.9 started"))
        #expect(lines[1].contains("Test: after launch"))
    }

    @Test("a read failure leaves a direct diagnostic line in the file, not only the unified log")
    internal func readFailureDiagnostic() async throws {
        let url = try temporaryLog()
        let reader = ScriptedLogReader(batches: [], failures: 1)
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url))
        await mirror.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("[error] UnifiedLogMirror: unified log read failed ("))
        #expect(text.contains("backing off 1 cycle(s); reader=ScriptedLogReader"))
        #expect(await mirror.readErrorCount == 1)
    }

    @Test("fifteen empty cycles with a heartbeat out hand the reader over, once, with a diagnostic")
    internal func zeroYieldHandOver() async throws {
        let url = try temporaryLog()
        let reader = SwitchableFakeReader(fallbackBatches: [[line(1, "from fallback")], [line(2, "still fallback")]])
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url))
        for _ in 0..<14 { await mirror.flush() }
        #expect(!reader.isSwitched)
        #expect(await mirror.heartbeatsLogged == 1, "one heartbeat after ten empty cycles")
        await mirror.flush() // the fifteenth
        #expect(reader.isSwitched)
        #expect(await mirror.handedOver)
        #expect(reader.reasons == ["no entries for 15 cycles although 1 heartbeat(s) were logged"])
        let afterHandOver = try String(contentsOf: url, encoding: .utf8)
        #expect(afterHandOver.contains("[notice] UnifiedLogMirror: no entries for 15 cycles although 1 heartbeat(s) were logged; handed over to Fallback"))
        await mirror.flush()
        await mirror.flush()
        for _ in 0..<20 { await mirror.flush() } // empty again: no second hand-over
        #expect(reader.reasons.count == 1)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("Test: from fallback"))
        #expect(text.contains("Test: still fallback"))
        #expect(await mirror.linesWritten == 2)
    }

    @Test("two distinct entries sharing one timestamp both survive; only a byte-identical re-delivery is dropped")
    internal func sameTimestampDistinctEntries() async throws {
        let url = try temporaryLog()
        let reader = ScriptedLogReader(batches: [
            [line(5, "alpha", level: "info"), line(5, "alpha", level: "error"), line(5, "beta")],
            [line(5, "beta"), line(5, "gamma")],
        ])
        let mirror = UnifiedLogMirror(reader: reader, appender: LogFileAppender(fileURL: url))
        await mirror.flush()
        await mirror.flush()
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines.map { $0.components(separatedBy: "] Test: ").last ?? "" } == ["alpha", "alpha", "beta", "gamma"])
        #expect(lines[0].contains("[info]") && lines[1].contains("[error]"))
    }

    @Test("the switching reader stays on the primary until it throws, then uses the fallback for good")
    internal func switching() throws {
        let primary = ScriptedLogReader(batches: [[line(1, "p1")]], failures: 0)
        let fallback = ScriptedLogReader(batches: [[line(2, "f1")], [line(3, "f2")]])
        let reader = SwitchingLogReader(primary: primary, fallback: fallback)
        #expect(try reader.entries(after: nil).map(\.message) == ["p1"])
        #expect(!reader.isUsingFallback())
        let failing = ScriptedLogReader(batches: [[line(9, "never")]], failures: 1)
        let switching = SwitchingLogReader(primary: failing, fallback: fallback)
        #expect(try switching.entries(after: nil).map(\.message) == ["f1"], "the first failure hands over in the same call")
        #expect(switching.isUsingFallback())
        #expect(try switching.entries(after: nil).map(\.message) == ["f2"])
        #expect(failing.calls.count == 1, "the primary is never asked again")
        #expect(switching.name == "ScriptedLogReader", "the fallback's name once switched")
        let requested = SwitchingLogReader(primary: ScriptedLogReader(batches: [[line(1, "p")]]), fallback: ScriptedLogReader(batches: [[line(2, "f")]]))
        requested.switchToFallback(reason: "asked")
        requested.switchToFallback(reason: "asked again")
        #expect(requested.isUsingFallback())
        #expect(try requested.entries(after: nil).map(\.message) == ["f"], "a requested hand-over skips the primary")
    }

    #if os(macOS)
    @Test("log stream records parse into entries; preamble and foreign subsystems are dropped")
    internal func logStreamParsing() {
        let record = """
        {"timestamp":"2026-09-26 10:00:00.123456+0000","messageType":"Error","category":"GatewayClient","subsystem":"com.ethenotethan.Portal","eventMessage":"socket closed"}
        """
        let parsed = LogStreamProcessReader.parseLine(record)
        #expect(parsed?.subsystem == "com.ethenotethan.Portal")
        #expect(parsed?.line.level == "error")
        #expect(parsed?.line.category == "GatewayClient")
        #expect(parsed?.line.message == "socket closed")
        #expect(parsed?.line.date == LogStreamProcessReader.parseTimestamp("2026-09-26 10:00:00.123456+0000"))
        #expect(LogStreamProcessReader.parseLine("Filtering the log data using \"subsystem == ...\"") == nil)
        #expect(LogStreamProcessReader.parseLine("{\"timestamp\":\"bad\",\"eventMessage\":\"x\"}") == nil)
        #expect(LogStreamProcessReader.parseLine("{\"eventMessage\":\"no stamp\"}") == nil)
        #expect(LogStreamProcessReader.levelName("Default") == "notice")
        #expect(LogStreamProcessReader.levelName("Info") == "info")
        #expect(LogStreamProcessReader.levelName("Debug") == "debug")
        #expect(LogStreamProcessReader.levelName("Fault") == "fault")
        #expect(LogStreamProcessReader.levelName("") == "unknown")
        #expect(LogStreamProcessReader.levelName("Signpost") == "signpost")
        let arguments = LogStreamProcessReader.arguments(subsystem: "com.ethenotethan.Portal", processIdentifier: 42)
        #expect(arguments.contains("--process") && arguments.contains("42"))
        #expect(arguments.last == "subsystem == \"com.ethenotethan.Portal\"")
        #expect(arguments.first == "stream")
    }

    @Test("the log stream reader buffers partial lines, keeps only its subsystem, and drains on read")
    internal func logStreamBuffering() throws {
        let reader = LogStreamProcessReader(subsystem: "com.ethenotethan.Portal", processIdentifier: 1, spawnsProcess: false)
        #expect(try reader.entries(after: nil).isEmpty)
        let first = """
        {"timestamp":"2026-09-26 10:00:00.000000+0000","messageType":"Default","category":"A","subsystem":"com.ethenotethan.Portal","eventMessage":"one"}
        {"timestamp":"2026-09-26 10:00:01.000000+0000","messageType":"Info","category":"B","subsystem":"other.app","eventMessage":"foreign"}
        {"timestamp":"2026-09-26 10:00:02.000000+0000","messageType":"Er
        """
        reader.ingest(Data(first.utf8))
        reader.ingest(Data())
        let drained = try reader.entries(after: nil)
        #expect(drained.map(\.message) == ["one"], "the foreign subsystem is dropped and the partial record waits")
        reader.ingest(Data("ror\",\"category\":\"C\",\"subsystem\":\"com.ethenotethan.Portal\",\"eventMessage\":\"two\"}\n".utf8))
        let rest = try reader.entries(after: nil)
        #expect(rest.map(\.message) == ["two"])
        #expect(rest.first?.level == "error")
        #expect(rest.first?.category == "C")
        #expect(try reader.entries(after: nil).isEmpty, "a drain empties the buffer")
        #expect(reader.processIdentifier == 1)
    }

    @Test("the real reader sees this process's own entries for the subsystem, or fails the way the mirror tolerates")
    internal func realReader() {
        let reader = OSLogStoreReader(subsystem: UnifiedLogMirror.subsystem)
        // The unified log store is not reachable from every test host (`swift test`
        // runs under xctest, where opening it throws); the mirror treats that as a
        // logged, backed-off failure, so here it is a known, intermittent issue.
        withKnownIssue("OSLogStore is unavailable in this test host", isIntermittent: true) {
            let entries = try reader.entries(after: Date().addingTimeInterval(-60))
            // The store only holds what this process logged; the suite may run first,
            // so assert the shape rather than a count.
            #expect(entries.allSatisfy { !$0.category.isEmpty && !$0.level.isEmpty })
        }
        #expect(OSLogStoreReader.levelName(.error) == "error")
        #expect(OSLogStoreReader.levelName(.debug) == "debug")
        #expect(OSLogStoreReader.levelName(.notice) == "notice")
        #expect(OSLogStoreReader.levelName(.fault) == "fault")
        #expect(OSLogStoreReader.levelName(.info) == "info")
        #expect(OSLogStoreReader.levelName(.undefined) == "undefined")
    }
    #endif
}
