import Foundation

// MARK: - Raw Session Event

/// One raw wire event from a backend's session event log — a Sendable
/// snapshot of an SSE frame (id + event name + data), the unit Centaur's
/// own web frontend renders. The chat pipeline adapts these into
/// `GatewayEvent`s and intentionally drops lifecycle noise; the Explorer's
/// Events tab shows them verbatim for protocol-level debugging.
struct RawSessionEvent: Identifiable, Sendable, Equatable {
    /// SSE event id (monotonic per thread on Centaur). Frames without a
    /// numeric id get a synthesized monotonic one so ForEach stays stable.
    let id: Int64
    /// SSE event name, e.g. "session.output.line", "session.execution_started".
    let name: String
    /// The frame's raw data field (JSON object or NDJSON line, verbatim).
    let payload: String
    /// Best-effort timestamp lifted from the payload, when it carries one.
    let timestamp: Date?
    /// For `session.output.line` NDJSON harness frames: the inner protocol
    /// method ("item/agentMessage/delta", …). nil for non-NDJSON payloads.
    let harnessMethod: String?

    init(id: Int64, name: String, payload: String) {
        self.id = id
        self.name = name
        self.payload = payload
        if let data = payload.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            self.harnessMethod = obj["method"] as? String
            self.timestamp = Self.timestamp(in: obj)
        } else {
            self.harnessMethod = nil
            self.timestamp = nil
        }
    }

    /// Pretty-printed payload for the expanded row; non-JSON payloads pass
    /// through verbatim.
    var prettyPayload: String {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: pretty, encoding: .utf8) else {
            return payload
        }
        return text
    }

    /// Best-effort timestamp keys seen across Centaur/api-rs payloads.
    private static func timestamp(in obj: [String: Any]) -> Date? {
        for key in ["timestamp", "created_at", "ts"] {
            guard let value = obj[key] else { continue }
            if let epoch = value as? Double { return Date(timeIntervalSince1970: epoch) }
            if let text = value as? String {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: text) { return date }
                iso.formatOptions = [.withInternetDateTime]
                if let date = iso.date(from: text) { return date }
            }
        }
        return nil
    }
}

// MARK: - Raw Event Log Collector

/// Turns SSE lines into `RawSessionEvent`s — `SSEParser` framing plus id
/// bookkeeping. Extracted from the network read loop so replay collection
/// is testable with synthetic frames.
struct RawEventLogCollector {
    private var parser = SSEParser()
    private var nextSyntheticID: Int64 = 0

    mutating func consume(line: String) -> RawSessionEvent? {
        guard let frame = parser.consume(line: line) else { return nil }
        return event(from: frame)
    }

    mutating func event(from frame: SSEParser.Frame) -> RawSessionEvent? {
        // Frames with neither data nor id are keepalive noise SSEParser
        // already suppresses; anything that reaches here is a real event.
        let id: Int64
        if let raw = frame.id, let numeric = Int64(raw) {
            id = numeric
        } else {
            id = nextSyntheticID
        }
        nextSyntheticID = id + 1
        return RawSessionEvent(id: id, name: frame.event, payload: frame.data)
    }
}

// MARK: - Raw Event Log Providing

/// Optional backend surface for the Explorer's Events tab: backends whose
/// wire protocol IS an event log (Centaur SSE) expose it raw. Hermes doesn't
/// conform — its `session.timeline` RPC already renders in the Timeline tab.
@MainActor
protocol RawEventLogProviding: AnyObject {
    /// One-shot replay of the session's raw event log from `afterEventID`
    /// (0 = full log). Implementations MUST NOT disturb any live-stream
    /// cursor they keep for the same session.
    func rawEventLog(sessionID: String, afterEventID: Int64) async throws -> [RawSessionEvent]
}
