import Foundation

private let healthBundleLog = PortalLogger(category: "Health")

/// What the monitor writes when the degraded state is detected, or when the
/// user asks: one folder under `…/Logs/Portal/diagnostics/<ISO8601>/` with the
/// health series and findings, the gateway's debug snapshot, the live-object
/// registries and counters, the tail of the app log, and thread backtraces (a
/// real all-thread `sample` on macOS when the tool cooperates). The README
/// says what triggered it and what each file is. Everything here is
/// best-effort: a file that cannot be produced is written as a note, and the
/// bundle is still complete enough to reason from.
internal struct DiagnosticBundleWriter: Sendable {
    /// Inputs the monitor hands over; all optional except the trigger.
    internal struct Contents: Sendable {
        internal var trigger: String
        internal var findings: [String]
        internal var samples: [SessionHealthSample]
        internal var gateway: GatewayDiagnosticSnapshot?
        internal var registries: LiveObjectRegistry.Snapshot
        internal var counters: HealthCounters.Snapshot
        internal var logURL: URL?
        internal var currentThreadSymbols: [String]
    }

    internal static let logTailLines = 2_000
    internal static let logTailBytes = 2 * 1024 * 1024
    internal static let sampleSeconds = 3

    internal let rootDirectory: URL
    /// Runs the all-thread sampler for `pid`; returns its text or throws. The
    /// default spawns `/usr/bin/sample`; tests inject a stub.
    internal let sampler: @Sendable (_ pid: Int32) throws -> String

    internal init(rootDirectory: URL, sampler: (@Sendable (Int32) throws -> String)? = nil) {
        self.rootDirectory = rootDirectory
        self.sampler = sampler ?? DiagnosticBundleWriter.runSampleTool
    }

    internal static func defaultRootDirectory() -> URL {
        PortalLogSink.defaultLogURL().deletingLastPathComponent().appendingPathComponent("diagnostics", isDirectory: true)
    }

    /// Writes the bundle and returns its folder.
    internal func write(_ contents: Contents, now: Date = Date(), pid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> URL {
        let folder = rootDirectory.appendingPathComponent(Self.folderName(for: now), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try writeJSON(["trigger": contents.trigger, "written_at": Self.iso8601(now), "findings": contents.findings,
                       "samples": try Self.encodeSamples(contents.samples)],
                      to: folder.appendingPathComponent("health.json"))
        if let gateway = contents.gateway {
            try writeEncodable(gateway, to: folder.appendingPathComponent("gateway.json"))
        } else {
            try writeJSON(["note": "gateway snapshot unavailable"], to: folder.appendingPathComponent("gateway.json"))
        }
        try writeJSON(["live": contents.registries.counts, "peaks": contents.registries.peaks, "counters": contents.counters.values],
                      to: folder.appendingPathComponent("registries.json"))
        try Self.logTail(from: contents.logURL).write(to: folder.appendingPathComponent("log-tail.txt"), atomically: true, encoding: .utf8)
        try threadsText(pid: pid, currentThread: contents.currentThreadSymbols)
            .write(to: folder.appendingPathComponent("threads.txt"), atomically: true, encoding: .utf8)
        try Self.readme(contents, folder: folder, now: now).write(to: folder.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        return folder
    }

    internal static func folderName(for date: Date) -> String {
        // Colons are legal on APFS but hostile to shells; keep the timestamp readable.
        iso8601(date).replacingOccurrences(of: ":", with: "-")
    }

    internal static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func encodeSamples(_ samples: [SessionHealthSample]) throws -> Any {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(samples)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func writeEncodable<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    /// The last `logTailLines` lines of the app log, reading at most `logTailBytes`.
    internal static func logTail(from url: URL?) -> String {
        guard let url else { return "app log location unknown\n" }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { closeQuietly(handle) }
            let size = try handle.seekToEnd()
            let start = size > UInt64(logTailBytes) ? size - UInt64(logTailBytes) : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            let text = String(bytes: data, encoding: .utf8) ?? "app log tail is not UTF-8"
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.suffix(logTailLines).joined(separator: "\n") + "\n"
        } catch {
            return "app log not readable at \(url.path): \(error)\n"
        }
    }

    /// Closing a read handle can only fail after the read succeeded; the tail is
    /// already in hand, so the failure is noted and otherwise ignored.
    private static func closeQuietly(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch {
            healthBundleLog.debug("log handle close failed: \(String(describing: error))")
        }
    }

    private func threadsText(pid: Int32, currentThread: [String]) -> String {
        var text = "Current thread (\(Thread.isMainThread ? "main" : "background")) at capture:\n"
        text += currentThread.isEmpty ? "  <no symbols>\n" : currentThread.map { "  \($0)" }.joined(separator: "\n") + "\n"
        text += "\nAll threads (`sample \(pid) \(Self.sampleSeconds)`):\n"
        do {
            text += try sampler(pid)
        } catch {
            text += "sample unavailable: \(error)\n"
            text += "Fallback: run `sample \(pid) 3 -file /tmp/portal.sample.txt` in Terminal while the app is in the bad state.\n"
        }
        return text
    }

    /// `/usr/bin/sample <pid> 3`: a real all-thread call-stack sample. Debug
    /// builds are samplable by the same user; hardened or sandboxed builds may
    /// refuse, and the caller records why.
    private static func runSampleTool(_ pid: Int32) throws -> String {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(pid), String(sampleSeconds)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(bytes: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw SampleToolError.exited(status: process.terminationStatus, output: String(text.suffix(400)))
        }
        return text
        #else
        throw SampleToolError.unsupportedPlatform
        #endif
    }

    internal enum SampleToolError: Error, CustomStringConvertible {
        case exited(status: Int32, output: String)
        case unsupportedPlatform

        internal var description: String {
            switch self {
            case .exited(let status, let output):
                return "sample exited with status \(status)" + (output.isEmpty ? "" : ": \(output)")
            case .unsupportedPlatform:
                return "no all-thread sampler on this platform"
            }
        }
    }

    private static func readme(_ contents: Contents, folder: URL, now: Date) -> String {
        let findings = contents.findings.isEmpty ? "  (none — manual capture)" : contents.findings.map { "  - \($0)" }.joined(separator: "\n")
        return """
        Portal diagnostic bundle
        ========================
        Written:  \(iso8601(now))
        Trigger:  \(contents.trigger)
        Findings:
        \(findings)

        Files
          health.json      the last \(contents.samples.count) health samples (one per interval) and the findings above
          gateway.json     the gateway client's debug snapshot: connection, pending requests, recent events, drops
          registries.json  live object counts and peaks (ChatViewModel, WKWebView, …) and the churn counters
          log-tail.txt     the last \(logTailLines) lines of portal.log before the capture
          threads.txt      the capturing thread's backtrace and an all-thread `sample` when available
          README.txt       this file

        What to do
          Send this whole folder (\(folder.lastPathComponent)) to whoever is diagnosing the long-session
          degradation. If the app is still in the bad state, also run in Terminal:
            sample Portal 5 -file ~/Desktop/portal-sample.txt
          and include that file.
        """ + "\n"
    }
}

// MARK: - Gateway snapshot, Sendable and Codable

/// The gateway client's debug snapshot flattened for the bundle: the fields a
/// diagnosis needs, as plain values, so it can cross from the main actor to the
/// monitor and be encoded without the client's own types.
internal struct GatewayDiagnosticSnapshot: Codable, Equatable, Sendable {
    internal struct Event: Codable, Equatable, Sendable {
        internal var timestamp: Date
        internal var direction: String
        internal var name: String
        internal var sessionID: String?
        internal var detail: String
    }

    internal struct DroppedReason: Codable, Equatable, Sendable {
        internal var reason: String
        internal var count: Int
        internal var lastAt: Date
    }

    internal var connectionState: String
    internal var socketURL: String
    internal var isAuthenticated: Bool
    internal var hasCFAuthCookie: Bool
    internal var activeSessionID: String?
    internal var lastSessionKey: String?
    internal var pendingRequestIDs: [Int]
    internal var pendingRequestMethods: [String: String]
    internal var reconnectAttempt: Int
    internal var lastOpenAt: Date?
    internal var lastCloseAt: Date?
    internal var lastErrorAt: Date?
    internal var lastError: String?
    internal var recentEvents: [Event]
    internal var droppedEventReasons: [DroppedReason]

    internal var pendingRequestCount: Int { pendingRequestIDs.count }

    internal init(_ snapshot: GatewayDebugSnapshot) {
        connectionState = snapshot.connectionState
        socketURL = snapshot.socketURL
        isAuthenticated = snapshot.isAuthenticated
        hasCFAuthCookie = snapshot.hasCFAuthCookie
        activeSessionID = snapshot.activeSessionID
        lastSessionKey = snapshot.lastSessionKey
        pendingRequestIDs = snapshot.pendingRequestIDs
        pendingRequestMethods = Dictionary(uniqueKeysWithValues: snapshot.pendingRequestMethods.map { (String($0.key), $0.value) })
        reconnectAttempt = snapshot.reconnectAttempt
        lastOpenAt = snapshot.lastOpenAt
        lastCloseAt = snapshot.lastCloseAt
        lastErrorAt = snapshot.lastErrorAt
        lastError = snapshot.lastError
        recentEvents = snapshot.recentEvents.map {
            Event(timestamp: $0.timestamp, direction: $0.direction.rawValue, name: $0.name, sessionID: $0.sessionID, detail: $0.detail)
        }
        droppedEventReasons = snapshot.droppedEventReasons.map { DroppedReason(reason: $0.reason, count: $0.count, lastAt: $0.lastAt) }
    }
}
