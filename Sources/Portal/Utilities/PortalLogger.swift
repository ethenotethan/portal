import Foundation
import os

// MARK: - Portal's logging facade and its declared file sink

/// The one logger Portal code declares. Every line goes two places: the unified
/// log (through `os.Logger`, subsystem `com.ethenotethan.Portal`) and the
/// process-wide `PortalLogSink`, which appends it to the file the architecture
/// standard declares for Portal (`~/Library/Logs/Portal/portal.log`).
///
/// The facade is why the file exists at all: a user-level app cannot read its
/// own unified log back (`OSLogStore` refuses the process scope and `log stream`
/// is admin-only), so the only way to make the declared sink real is to write it
/// at the call site. Messages are built with string interpolation exactly like
/// `OSLogMessage` — `privacy:` and `format:` arguments still compile — but every
/// value is rendered in the clear, because the same text lands in the user's
/// own file. Secrets must never be logged; that is a call-site rule, not a
/// privacy modifier.
internal struct PortalLogger: Sendable {
    internal static let subsystem = "com.ethenotethan.Portal"

    internal let category: String
    private let osLogger: Logger
    private let sink: PortalLogSink

    internal init(category: String, sink: PortalLogSink = portalLogSink) {
        self.category = category
        self.osLogger = Logger(subsystem: Self.subsystem, category: category)
        self.sink = sink
    }

    internal func debug(_ message: PortalLogMessage) { emit(.debug, "debug", message) }
    internal func info(_ message: PortalLogMessage) { emit(.info, "info", message) }
    internal func notice(_ message: PortalLogMessage) { emit(.default, "notice", message) }
    /// `os.Logger.log(_:)` is the default level; kept so call sites read the same.
    internal func log(_ message: PortalLogMessage) { emit(.default, "notice", message) }
    /// `os.Logger.warning` is the error level under another name; the file keeps the name.
    internal func warning(_ message: PortalLogMessage) { emit(.error, "warning", message) }
    internal func error(_ message: PortalLogMessage) { emit(.error, "error", message) }
    internal func fault(_ message: PortalLogMessage) { emit(.fault, "fault", message) }

    private func emit(_ type: OSLogType, _ level: String, _ message: PortalLogMessage) {
        osLogger.log(level: type, "\(message.text, privacy: .public)")
        sink.record(level: level, category: category, message: message.text)
    }
}

// MARK: - Message

/// The text of a log line, built by string interpolation. Accepts the `privacy:`
/// and `format:` interpolation arguments `OSLogMessage` accepts, so a call site
/// written against `os.Logger` compiles unchanged; every value renders in the
/// clear (see `PortalLogger`).
internal struct PortalLogMessage: ExpressibleByStringInterpolation, Sendable {
    internal let text: String

    internal init(stringLiteral value: String) {
        text = value
    }

    internal init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.output
    }

    internal struct StringInterpolation: StringInterpolationProtocol {
        internal var output = ""

        internal init(literalCapacity: Int, interpolationCount: Int) {
            output.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        internal mutating func appendLiteral(_ literal: String) {
            output += literal
        }

        internal mutating func appendInterpolation<T>(_ value: T) {
            output += String(describing: value)
        }

        internal mutating func appendInterpolation<T>(_ value: T, privacy: PortalLogPrivacy) {
            output += String(describing: value)
        }

        internal mutating func appendInterpolation(_ value: Double, format: PortalLogFloatFormat) {
            output += format.render(value)
        }

        internal mutating func appendInterpolation(_ value: Double, format: PortalLogFloatFormat, privacy: PortalLogPrivacy) {
            output += format.render(value)
        }
    }
}

/// Accepted for source compatibility with `OSLogPrivacy`; the file renders
/// every value in the clear regardless.
internal enum PortalLogPrivacy: Sendable {
    case `public`
    case `private`
    case sensitive
    case auto
}

/// The float formatting `OSLogMessage` offers that Portal uses.
internal enum PortalLogFloatFormat: Sendable {
    case fixed(precision: Int)

    internal func render(_ value: Double) -> String {
        switch self {
        case .fixed(let precision):
            return String(format: "%.\(max(0, precision))f", value)
        }
    }
}

// MARK: - The file sink

/// The process-wide sink `PortalLogger` hands every line to. Lines are
/// formatted at the call site's moment, queued, and appended on a serial utility
/// queue so no caller ever blocks on the file; the queue is bounded, and when it
/// overflows the sink drops lines and says so in the file once it drains. The
/// file rotates once at 8 MiB (`portal.log.1` keeps the previous generation).
internal final class PortalLogSink: Sendable {
    internal static let diagnosticCategory = "PortalLogSink"
    internal static let defaultMaxQueued = 5_000

    /// What the sink has done so far, for tests and the startup line.
    internal struct Statistics: Equatable, Sendable {
        internal var queued = 0
        internal var dropped = 0
        internal var linesWritten = 0
        internal var writeFailures = 0
        internal var started = false
    }

    internal let appender: LogFileAppender
    private let queue: DispatchQueue
    private let maxQueued: Int
    private let state = OSAllocatedUnfairLock(initialState: Statistics())

    internal init(
        appender: LogFileAppender,
        maxQueued: Int = PortalLogSink.defaultMaxQueued,
        queue: DispatchQueue = DispatchQueue(label: "com.ethenotethan.Portal.log-sink", qos: .utility)
    ) {
        self.appender = appender
        self.maxQueued = maxQueued
        self.queue = queue
    }

    /// Where Portal's declared sink lives: `~/Library/Logs/Portal/portal.log` on
    /// macOS, the sandbox's own `Library/Logs/Portal/portal.log` on iOS.
    internal static func defaultLogURL(fileManager: FileManager = .default) -> URL {
        let library: URL
        #if os(macOS)
        library = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        #else
        library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory.appendingPathComponent("Library", isDirectory: true)
        #endif
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Portal", isDirectory: true)
            .appendingPathComponent("portal.log", isDirectory: false)
    }

    /// One line: `2026-09-26T10:00:00.000Z [info] Category: message`, with line
    /// breaks inside the message escaped so one entry stays one line.
    internal static func formatLine(date: Date, level: String, category: String, message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        return "\(timestampFormatter().string(from: date)) [\(level)] \(category): \(escaped)"
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is not Sendable, and a
    /// shared static would be a concurrency hole for a value this cheap to make.
    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// Queues one line. Returns immediately; the write happens on the sink's
    /// queue. When the queue is full the line is dropped and counted.
    internal func record(level: String, category: String, message: String) {
        let line = Self.formatLine(date: Date(), level: level, category: category, message: message)
        enqueue([line])
    }

    /// Writes the startup line straight away and arranges a final flush when the
    /// app terminates or goes to the background. Once per process.
    internal func start(appVersion: String) {
        let first = state.withLock { statistics -> Bool in
            guard !statistics.started else { return false }
            statistics.started = true
            return true
        }
        guard first else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        record(
            level: "notice",
            category: Self.diagnosticCategory,
            message: "Portal \(appVersion) started; pid=\(pid); sink=\(appender.fileURL.path)"
        )
        observeLifecycle()
    }

    /// Blocks until every queued line has been written. For shutdown and tests.
    internal func flush() {
        queue.sync { }
    }

    internal func snapshot() -> Statistics {
        state.withLock { $0 }
    }

    private func enqueue(_ lines: [String]) {
        let admitted = state.withLock { statistics -> Bool in
            guard statistics.queued + lines.count <= maxQueued else {
                statistics.dropped += lines.count
                return false
            }
            statistics.queued += lines.count
            return true
        }
        guard admitted else { return }
        queue.async { [self] in
            write(lines)
        }
    }

    private func write(_ lines: [String]) {
        let dropped = state.withLock { statistics -> Int in
            statistics.queued -= lines.count
            let dropped = statistics.dropped
            statistics.dropped = 0
            return dropped
        }
        var payload = lines
        if dropped > 0 {
            payload.insert(
                Self.formatLine(
                    date: Date(),
                    level: "error",
                    category: Self.diagnosticCategory,
                    message: "dropped \(dropped) line(s): sink queue full (\(maxQueued))"
                ),
                at: 0
            )
        }
        let written = payload.count
        do {
            try appender.append(payload)
            state.withLock { $0.linesWritten += written }
        } catch {
            let failures = state.withLock { statistics -> Int in
                statistics.writeFailures += 1
                return statistics.writeFailures
            }
            if failures == 1 {
                // Not through the facade: a failing sink must not feed itself.
                Logger(subsystem: PortalLogger.subsystem, category: Self.diagnosticCategory)
                    .error("log file write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func observeLifecycle() {
        #if canImport(AppKit) && os(macOS)
        NotificationCenter.default.addObserver(
            forName: NSApplicationWillTerminateNotificationName, object: nil, queue: nil
        ) { [self] _ in flush() }
        #elseif canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplicationDidEnterBackgroundNotificationName, object: nil, queue: nil
        ) { [self] _ in flush() }
        #endif
    }
}

#if canImport(AppKit) && os(macOS)
import AppKit
private let NSApplicationWillTerminateNotificationName = NSApplication.willTerminateNotification
#elseif canImport(UIKit)
import UIKit
private let UIApplicationDidEnterBackgroundNotificationName = UIApplication.didEnterBackgroundNotification
#endif

/// The process-wide sink every `PortalLogger` writes to by default. A module
/// constant rather than a `shared` static: it is the one log file this process
/// owns, and a test hands its logger a sink of its own instead.
internal let portalLogSink = PortalLogSink(appender: LogFileAppender(fileURL: PortalLogSink.defaultLogURL()))

// MARK: - The file

/// Appends lines to the log file, creating its directory and rotating the file
/// once (`portal.log` → `portal.log.1`) when it grows past the threshold. Pure
/// file work with injected paths so a test can drive it on a temp directory.
internal struct LogFileAppender: Sendable {
    internal let fileURL: URL
    internal let rotationThresholdBytes: Int

    internal init(fileURL: URL, rotationThresholdBytes: Int = 8 * 1024 * 1024) {
        self.fileURL = fileURL
        self.rotationThresholdBytes = rotationThresholdBytes
    }

    /// `FileManager` is not Sendable, so the appender reaches for the shared one
    /// at each use instead of storing it.
    private var fileManager: FileManager { .default }

    /// The previous generation the rotation keeps.
    internal var rotatedURL: URL {
        fileURL.appendingPathExtension("1")
    }

    /// Appends `lines` (each becomes one line) and returns the file size afterwards.
    @discardableResult
    internal func append(_ lines: [String]) throws -> Int {
        guard !lines.isEmpty else { return currentSize() }
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if currentSize() > rotationThresholdBytes {
            try rotate()
        }
        let payload = Data((lines.joined(separator: "\n") + "\n").utf8)
        if fileManager.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            try handle.close()
        } else {
            try payload.write(to: fileURL, options: .atomic)
        }
        return currentSize()
    }

    /// Zero when the file does not exist yet; any other failure to stat the
    /// file also reads as zero, which only means "do not rotate yet".
    internal func currentSize() -> Int {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
            return (attributes[.size] as? NSNumber)?.intValue ?? 0
        } catch {
            return 0
        }
    }

    private func rotate() throws {
        if fileManager.fileExists(atPath: rotatedURL.path) {
            try fileManager.removeItem(at: rotatedURL)
        }
        try fileManager.moveItem(at: fileURL, to: rotatedURL)
    }
}
