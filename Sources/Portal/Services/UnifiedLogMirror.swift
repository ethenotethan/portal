import Foundation
import os
import OSLog

private let mirrorLog = Logger(subsystem: UnifiedLogMirror.subsystem, category: UnifiedLogMirror.category)

// MARK: - Portal's declared log sink

/// One unified-log record reduced to what the file keeps.
internal struct UnifiedLogLine: Sendable, Equatable {
    internal let date: Date
    internal let level: String
    internal let category: String
    internal let message: String
}

/// Where unified-log entries come from. The real reader wraps `OSLogStore`;
/// tests hand the mirror a scripted one.
internal protocol UnifiedLogReading: Sendable {
    /// Entries for the app's subsystem newer than `after` (all of them when nil),
    /// oldest first.
    func entries(after: Date?) throws -> [UnifiedLogLine]
}

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

/// Mirrors this process's unified-log entries (subsystem `com.ethenotethan.Portal`,
/// every category) into `~/Library/Logs/Portal/portal.log`, the file Portal's
/// architecture manifest declares as its log sink. Portal logs through
/// `os.Logger`, which only the unified log receives; the standard now requires a
/// capturable sink, and this is how the declared file becomes real without
/// touching a single call site.
///
/// Runs entirely off the main actor (it is an actor on the default executor),
/// polls on a fixed cadence while started, flushes on demand, and fails open:
/// a reader or writer error is logged once and the mirror backs off, doubling
/// its wait up to a minute, rather than failing the app.
internal actor UnifiedLogMirror {
    internal static let subsystem = "com.ethenotethan.Portal"
    internal static let category = "LogMirror"
    internal static let maxBackoffCycles = 30

    private let reader: any UnifiedLogReading
    private let appender: LogFileAppender
    private let cadence: Duration
    private var lastDate: Date?
    /// Signatures of the entries that share `lastDate`, so a batch boundary that
    /// falls inside one timestamp does not duplicate or drop an entry.
    private var lastDateSignatures: Set<String> = []
    private var backoffCycles = 0
    private var backoffStep = 0
    private var loop: Task<Void, Never>?
    internal private(set) var readErrorCount = 0
    internal private(set) var writeErrorCount = 0
    internal private(set) var linesWritten = 0

    internal init(reader: any UnifiedLogReading, appender: LogFileAppender, cadence: Duration = .seconds(2)) {
        self.reader = reader
        self.appender = appender
        self.cadence = cadence
    }

    internal var fileURL: URL { appender.fileURL }
    internal var isBackingOff: Bool { backoffCycles > 0 }

    /// The declared sink: `~/Library/Logs/Portal/portal.log` on macOS; the app's
    /// own `Library/Logs/Portal/portal.log` on iOS, where the home directory is
    /// the sandbox container.
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

    /// One entry as one line: `2026-09-26T10:00:00.000Z [info] Category: message`.
    /// Line breaks inside a message are escaped so a tail stays line-oriented.
    internal static func formatEntry(_ line: UnifiedLogLine) -> String {
        let escaped = line.message
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
        return "\(Self.timestampFormatter().string(from: line.date)) [\(line.level)] \(line.category): \(escaped)"
    }

    /// A fresh formatter per call: `ISO8601DateFormatter` is not Sendable, and a
    /// shared static would be a concurrency hole for a value this cheap to make.
    private static func timestampFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }

    /// Starts the polling loop and writes the startup line through the unified
    /// log, so the file is never empty while the app runs.
    internal func start(appVersion: String) {
        guard loop == nil else { return }
        mirrorLog.notice("Portal \(appVersion, privacy: .public) started; mirroring unified log to \(self.appender.fileURL.path, privacy: .public)")
        loop = Task { [cadence] in
            while !Task.isCancelled {
                await self.flush()
                do {
                    try await Task.sleep(for: cadence)
                } catch {
                    return // cancelled
                }
            }
        }
    }

    internal func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One pass: read what is new, append it, advance the position. Honours the
    /// back-off after an error.
    internal func flush() {
        if backoffCycles > 0 {
            backoffCycles -= 1
            return
        }
        let fresh: [UnifiedLogLine]
        do {
            fresh = try reader.entries(after: lastDate).filter(isUnseen)
        } catch {
            readErrorCount += 1
            backOff(after: "unified log read", error: error)
            return
        }
        guard !fresh.isEmpty else {
            backoffStep = 0
            return
        }
        do {
            try appender.append(fresh.map(Self.formatEntry))
            linesWritten += fresh.count
            advance(past: fresh)
            backoffStep = 0
        } catch {
            writeErrorCount += 1
            backOff(after: "log file write", error: error)
        }
    }

    private func isUnseen(_ line: UnifiedLogLine) -> Bool {
        guard let lastDate else { return true }
        if line.date > lastDate { return true }
        if line.date < lastDate { return false }
        return !lastDateSignatures.contains(Self.signature(line))
    }

    private func advance(past lines: [UnifiedLogLine]) {
        guard let newest = lines.map(\.date).max() else { return }
        if newest != lastDate {
            lastDateSignatures.removeAll()
        }
        lastDate = newest
        for line in lines where line.date == newest {
            lastDateSignatures.insert(Self.signature(line))
        }
    }

    private static func signature(_ line: UnifiedLogLine) -> String {
        "\(line.level)|\(line.category)|\(line.message)"
    }

    /// Doubles the wait each consecutive failure (1, 2, 4, … up to 30 cycles);
    /// the first failure of a run is logged, the rest stay quiet.
    private func backOff(after what: String, error: Error) {
        if backoffStep == 0 {
            mirrorLog.error("\(what, privacy: .public) failed; backing off: \(String(describing: error), privacy: .public)")
        }
        backoffCycles = min(Self.maxBackoffCycles, 1 << min(backoffStep, 5))
        backoffStep += 1
    }
}

// MARK: - The real reader

/// Reads this process's own entries from the unified log (`OSLogStore`, macOS 12
/// and iOS 15 onwards; the process scope needs no entitlement on either).
internal struct OSLogStoreReader: UnifiedLogReading {
    internal let subsystem: String

    internal init(subsystem: String = UnifiedLogMirror.subsystem) {
        self.subsystem = subsystem
    }

    internal func entries(after: Date?) throws -> [UnifiedLogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = after.map { store.position(date: $0) } ?? store.position(timeIntervalSinceLatestBoot: 0)
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        return try store.getEntries(at: position, matching: predicate).compactMap { entry in
            guard let record = entry as? OSLogEntryLog else { return nil }
            return UnifiedLogLine(
                date: record.date,
                level: Self.levelName(record.level),
                category: record.category,
                message: record.composedMessage
            )
        }
    }

    internal static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "undefined"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - Fallback: the `log stream` command

#if os(macOS)
/// Reads this process's entries by running `/usr/bin/log stream --process <pid>`
/// and parsing its NDJSON output. The fallback for hosts where `OSLogStore`
/// refuses the process scope (it throws with no error on some configurations):
/// the `log` tool speaks to logd on the app's behalf without an entitlement.
/// Pull-based like the store reader: the child's lines accumulate in a locked
/// buffer and `entries(after:)` drains it.
internal final class LogStreamProcessReader: UnifiedLogReading, @unchecked Sendable {
    internal let subsystem: String
    internal let processIdentifier: Int32
    private let lock = NSLock()
    private var buffer: [UnifiedLogLine] = []
    private var process: Process?
    private var pipe: Pipe?
    private var partial = Data()

    /// `spawnsProcess: false` keeps the child unlaunched so a test can feed
    /// `ingest(_:)` directly and drain the buffer.
    private let spawnsProcess: Bool

    internal init(
        subsystem: String = UnifiedLogMirror.subsystem,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        spawnsProcess: Bool = true
    ) {
        self.subsystem = subsystem
        self.processIdentifier = processIdentifier
        self.spawnsProcess = spawnsProcess
    }

    deinit {
        process?.terminate()
    }

    internal func entries(after: Date?) throws -> [UnifiedLogLine] {
        if spawnsProcess {
            try startIfNeeded()
        }
        lock.lock()
        defer { lock.unlock() }
        let drained = buffer
        buffer.removeAll(keepingCapacity: true)
        return drained
    }

    /// The `log stream` invocation, exposed so a test can pin the exact command.
    internal static func arguments(subsystem: String, processIdentifier: Int32) -> [String] {
        [
            "stream", "--style", "ndjson", "--level", "debug", "--process", String(processIdentifier),
            "--predicate", "subsystem == \"\(subsystem)\"",
        ]
    }

    private func startIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning { return }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        child.arguments = Self.arguments(subsystem: subsystem, processIdentifier: processIdentifier)
        child.standardError = FileHandle.nullDevice
        let output = Pipe()
        child.standardOutput = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.ingest(handle.availableData)
        }
        try child.run()
        process = child
        pipe = output
    }

    /// Feeds raw child output: complete lines become entries, a trailing partial
    /// line waits for the rest.
    internal func ingest(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        partial.append(data)
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            let chunk = partial.subdata(in: partial.startIndex..<newline)
            partial.removeSubrange(partial.startIndex...newline)
            guard let text = String(bytes: chunk, encoding: .utf8) else { continue }
            if let line = Self.parseLine(text), line.subsystem == subsystem {
                buffer.append(line.line)
            }
        }
    }

    /// One NDJSON record → an entry. `nil` for anything that is not a log record
    /// (the tool's own preamble, malformed output).
    internal static func parseLine(_ text: String) -> (line: UnifiedLogLine, subsystem: String)? {
        guard let data = text.data(using: .utf8) else { return nil }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil // the tool's preamble and truncated records are not JSON
        }
        guard let object = parsed as? [String: Any],
              let message = object["eventMessage"] as? String,
              let stamp = object["timestamp"] as? String,
              let date = Self.parseTimestamp(stamp) else { return nil }
        let line = UnifiedLogLine(
            date: date,
            level: Self.levelName(object["messageType"] as? String ?? ""),
            category: object["category"] as? String ?? "",
            message: message
        )
        return (line, object["subsystem"] as? String ?? "")
    }

    /// `log` prints `2026-09-26 10:00:00.123456+0000`.
    internal static func parseTimestamp(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        return formatter.date(from: text)
    }

    internal static func levelName(_ messageType: String) -> String {
        switch messageType {
        case "Default": return "notice"
        case "Info": return "info"
        case "Debug": return "debug"
        case "Error": return "error"
        case "Fault": return "fault"
        default: return messageType.isEmpty ? "unknown" : messageType.lowercased()
        }
    }
}
#endif

/// Uses the primary reader until it throws once, then the fallback for the rest
/// of the process's life. The switch is logged once.
internal final class SwitchingLogReader: UnifiedLogReading, @unchecked Sendable {
    private let primary: any UnifiedLogReading
    private let fallback: any UnifiedLogReading
    private let lock = NSLock()
    private var usingFallback = false

    internal init(primary: any UnifiedLogReading, fallback: any UnifiedLogReading) {
        self.primary = primary
        self.fallback = fallback
    }

    /// A method rather than a property: the architecture compiler scopes lock
    /// operations to their enclosing function, and a getter has none.
    internal func isUsingFallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingFallback
    }

    internal func entries(after: Date?) throws -> [UnifiedLogLine] {
        if !isUsingFallback() {
            do {
                return try primary.entries(after: after)
            } catch {
                lock.lock()
                usingFallback = true
                lock.unlock()
                mirrorLog.notice("unified log store unavailable (\(String(describing: error), privacy: .public)); switching to the log stream fallback")
            }
        }
        return try fallback.entries(after: after)
    }
}
