import Testing
import Foundation
@testable import Portal

@Suite("PortalLogger — the facade and Portal's declared log sink")
internal struct PortalLoggerTests {
    private static let epoch = Date(timeIntervalSince1970: 1_790_000_000)

    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("portal-log-sink-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Logs/Portal/portal.log", isDirectory: false)
    }

    private func lines(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    // MARK: Pure helpers

    @Test("the default sink is Library/Logs/Portal/portal.log")
    internal func defaultPath() {
        let url = PortalLogSink.defaultLogURL()
        #expect(url.lastPathComponent == "portal.log")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Portal")
        #expect(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Logs")
        #expect(url.pathComponents.contains("Library"))
        #expect(url.isFileURL)
    }

    @Test("a line is ISO8601, level, category and the message with line breaks escaped")
    internal func formatting() {
        let formatted = PortalLogSink.formatLine(
            date: Self.epoch.addingTimeInterval(0.5), level: "error", category: "GatewayClient",
            message: "first\nsecond\r\nthird\rfourth"
        )
        #expect(formatted == "2026-09-21T14:13:20.500Z [error] GatewayClient: first\\nsecond\\nthird\\nfourth")
        #expect(!formatted.contains("\n"))
    }

    @Test("messages interpolate like OSLogMessage: privacy and format arguments compile and render in the clear")
    internal func messageInterpolation() {
        let token = "abc"
        let count = 3
        let seconds = 2.71828
        let plain: PortalLogMessage = "count=\(count) token=\(token, privacy: .public) hidden=\(token, privacy: .private)"
        #expect(plain.text == "count=3 token=abc hidden=abc")
        let formatted: PortalLogMessage = "took \(seconds, format: .fixed(precision: 1))s and \(seconds, format: .fixed(precision: 0), privacy: .public)s"
        #expect(formatted.text == "took 2.7s and 3s")
        let literal: PortalLogMessage = "plain literal"
        #expect(literal.text == "plain literal")
        #expect(PortalLogFloatFormat.fixed(precision: -2).render(1.5) == "2", "a negative precision clamps to zero")
        let optional: String? = nil
        let described: PortalLogMessage = "value=\(optional as Any)"
        #expect(described.text.hasPrefix("value="))
    }

    // MARK: Appender

    @Test("appending creates the directory, keeps one line per entry and reports the size")
    internal func appendCreatesAndGrows() throws {
        let url = temporaryLog()
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
        let url = temporaryLog()
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

    // MARK: Sink

    @Test("recorded lines land in the file after a flush, in order, formatted")
    internal func recordAndFlush() throws {
        let url = temporaryLog()
        let sink = PortalLogSink(appender: LogFileAppender(fileURL: url))
        sink.record(level: "info", category: "A", message: "one")
        sink.record(level: "error", category: "B", message: "two\nlines")
        sink.flush()
        let written = try lines(at: url)
        #expect(written.count == 2)
        #expect(written[0].hasSuffix(" [info] A: one"))
        #expect(written[1].hasSuffix(" [error] B: two\\nlines"))
        let statistics = sink.snapshot()
        #expect(statistics.queued == 0)
        #expect(statistics.linesWritten == 2)
        #expect(statistics.dropped == 0)
        #expect(statistics.writeFailures == 0)
    }

    @Test("record never blocks the caller: with the queue suspended it returns, and the write happens on resume")
    internal func recordIsAsynchronous() throws {
        let url = temporaryLog()
        let queue = DispatchQueue(label: "test.portal.log-sink")
        let sink = PortalLogSink(appender: LogFileAppender(fileURL: url), queue: queue)
        queue.suspend()
        sink.record(level: "info", category: "A", message: "queued")
        #expect(sink.snapshot().queued == 1)
        #expect(!FileManager.default.fileExists(atPath: url.path), "nothing is written while the queue is suspended")
        queue.resume()
        sink.flush()
        #expect(try lines(at: url).count == 1)
        #expect(sink.snapshot().queued == 0)
    }

    @Test("a full queue drops lines, counts them, and says so in the file once it drains")
    internal func overflowIsCountedAndReported() throws {
        let url = temporaryLog()
        let queue = DispatchQueue(label: "test.portal.log-sink.overflow")
        let sink = PortalLogSink(appender: LogFileAppender(fileURL: url), maxQueued: 2, queue: queue)
        queue.suspend()
        for index in 0..<5 {
            sink.record(level: "info", category: "A", message: "line \(index)")
        }
        #expect(sink.snapshot().queued == 2)
        #expect(sink.snapshot().dropped == 3)
        queue.resume()
        sink.flush()
        let written = try lines(at: url)
        #expect(written.count == 3, "two kept lines plus one diagnostic")
        #expect(written[0].contains("[error] PortalLogSink: dropped 3 line(s): sink queue full (2)"))
        #expect(written[1].hasSuffix("A: line 0"))
        #expect(written[2].hasSuffix("A: line 1"))
        #expect(sink.snapshot().dropped == 0, "reported once")
        #expect(sink.snapshot().linesWritten == 3)
    }

    @Test("a write failure is counted and never fed back into the sink")
    internal func writeFailure() {
        // A file URL whose parent cannot be created: a regular file where the directory should be.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("portal-log-blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let url = blocker.appendingPathComponent("Portal/portal.log")
        let sink = PortalLogSink(appender: LogFileAppender(fileURL: url))
        sink.record(level: "info", category: "A", message: "doomed")
        sink.record(level: "info", category: "A", message: "doomed too")
        sink.flush()
        let statistics = sink.snapshot()
        #expect(statistics.writeFailures == 2)
        #expect(statistics.linesWritten == 0)
        #expect(statistics.queued == 0)
    }

    @Test("start writes the startup line once, with the version, pid and sink path")
    internal func startupLine() throws {
        let url = temporaryLog()
        let sink = PortalLogSink(appender: LogFileAppender(fileURL: url))
        sink.start(appVersion: "9.9")
        sink.start(appVersion: "9.9")
        sink.flush()
        let written = try lines(at: url)
        #expect(written.count == 1, "starting twice writes one startup line")
        #expect(written[0].contains("[notice] PortalLogSink: Portal 9.9 started; pid=\(ProcessInfo.processInfo.processIdentifier); sink=\(url.path)"))
        #expect(sink.snapshot().started)
    }

    // MARK: Facade

    @Test("every facade level reaches the sink under its own name and the logger's category")
    internal func facadeLevels() throws {
        let url = temporaryLog()
        let sink = PortalLogSink(appender: LogFileAppender(fileURL: url))
        let log = PortalLogger(category: "Facade", sink: sink)
        #expect(log.category == "Facade")
        #expect(PortalLogger.subsystem == "com.ethenotethan.Portal")
        let value = 42
        log.debug("d \(value)")
        log.info("i \(value, privacy: .public)")
        log.notice("n")
        log.log("l")
        log.warning("w")
        log.error("e")
        log.fault("f")
        sink.flush()
        let written = try lines(at: url).map { line in
            line.split(separator: " ", maxSplits: 1).last.map(String.init) ?? line
        }
        #expect(written == [
            "[debug] Facade: d 42", "[info] Facade: i 42", "[notice] Facade: n", "[notice] Facade: l",
            "[warning] Facade: w", "[error] Facade: e", "[fault] Facade: f",
        ])
    }

    @Test("the process-wide sink points at the default path")
    internal func processWideSink() {
        #expect(portalLogSink.appender.fileURL == PortalLogSink.defaultLogURL())
        #expect(portalLogSink.appender.rotationThresholdBytes == 8 * 1024 * 1024)
    }
}
