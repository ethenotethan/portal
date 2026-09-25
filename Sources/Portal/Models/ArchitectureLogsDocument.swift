import Foundation

// MARK: - Log capture (architecture.logs / architecture.logs.follow)

/// One log sink a local service's manifest declares, resolved by the gateway at
/// call time: a file, a directory of rotating files (the newest is the active
/// file), or the bound launchd job's stdout/stderr. Only declared sinks are ever
/// read, so a sink is the whole address a client can name.
internal struct ArchitectureLogSink: Hashable, Identifiable {
    internal let id: String
    internal let kind: String
    internal let label: String
    internal let path: String
    internal let exists: Bool
    internal let sizeBytes: Int
    internal let modifiedAt: String

    /// A human name for the sink kind.
    internal var kindLabel: String {
        switch kind {
        case "file": return "File"
        case "directory": return "Directory"
        case "launchd_stdout": return "launchd stdout"
        case "launchd_stderr": return "launchd stderr"
        default: return kind
        }
    }

    /// The file size in a short unit, or "missing" when the sink is not there.
    internal var sizeLabel: String {
        guard exists else { return "missing" }
        return Self.formatBytes(sizeBytes)
    }

    internal var displayLabel: String { label.isEmpty ? id : label }

    internal static func formatBytes(_ bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(max(bytes, 0))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(value)) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
    }

    internal static func decodeGatewayValue(_ value: AnyCodable) -> ArchitectureLogSink? {
        guard let d = value.dictionaryValue, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArchitectureLogSink(
            id: id,
            kind: d["kind"]?.stringValue ?? "file",
            label: d["label"]?.stringValue ?? "",
            path: d["path"]?.stringValue ?? "",
            exists: d["exists"]?.boolValue ?? false,
            sizeBytes: d["size_bytes"]?.intValue ?? 0,
            modifiedAt: d["modified_at"]?.stringValue ?? ""
        )
    }

    /// Every sink in a `logs` array; absent or malformed entries are skipped.
    internal static func decodeList(_ value: AnyCodable?) -> [ArchitectureLogSink] {
        (value?.arrayValue ?? []).compactMap(decodeGatewayValue)
    }
}

/// What `architecture.logs` returns: the last lines of a sink (no cursor) or the
/// complete lines appended since a cursor, with the cursor to continue from.
internal struct ArchitectureLogTail: Hashable {
    internal let service: String
    internal let sink: ArchitectureLogSink?
    internal let sinks: [ArchitectureLogSink]
    internal let lines: [String]
    internal let cursor: String
    internal let truncated: Bool
    internal let rotated: Bool
    internal let encoding: String

    internal static func decodeGatewayValue(_ value: AnyCodable) throws -> ArchitectureLogTail {
        guard let d = value.dictionaryValue, let lines = d["lines"]?.arrayValue else {
            throw GatewayError.invalidResponse("architecture.logs returned no lines")
        }
        return ArchitectureLogTail(
            service: d["service"]?.stringValue ?? "",
            sink: d["sink"].flatMap(ArchitectureLogSink.decodeGatewayValue),
            sinks: ArchitectureLogSink.decodeList(d["sinks"]),
            lines: lines.compactMap(\.stringValue),
            cursor: d["cursor"]?.stringValue ?? "",
            truncated: d["truncated"]?.boolValue ?? false,
            rotated: d["rotated"]?.boolValue ?? false,
            encoding: d["encoding"]?.stringValue ?? "utf-8-replace"
        )
    }
}

/// What `architecture.logs.follow` returns: whether the gateway is now
/// following the sink, and the cursor its first event will continue from.
internal struct ArchitectureLogFollowState: Hashable {
    internal let following: Bool
    internal let sink: ArchitectureLogSink?
    internal let cursor: String

    internal static func decodeGatewayValue(_ value: AnyCodable) throws -> ArchitectureLogFollowState {
        guard let d = value.dictionaryValue, let following = d["following"]?.boolValue else {
            throw GatewayError.invalidResponse("architecture.logs.follow returned no follow state")
        }
        return ArchitectureLogFollowState(
            following: following,
            sink: d["sink"].flatMap(ArchitectureLogSink.decodeGatewayValue),
            cursor: d["cursor"]?.stringValue ?? ""
        )
    }
}

/// The `architecture.log` event a followed sink emits: new complete lines and
/// the cursor after them; `rotated` when the file shrank and the tail restarted;
/// `stopped` when the gateway ended the follow (`"idle-timeout"`).
internal struct ArchitectureLogEvent: Hashable {
    internal let service: String
    internal let sink: String
    internal let lines: [String]
    internal let cursor: String
    internal let rotated: Bool
    internal let stopped: String?

    internal static func decodePayload(_ payload: [String: AnyCodable]) -> ArchitectureLogEvent {
        ArchitectureLogEvent(
            service: payload["service"]?.stringValue ?? "",
            sink: payload["sink"]?.stringValue ?? "",
            lines: (payload["lines"]?.arrayValue ?? []).compactMap(\.stringValue),
            cursor: payload["cursor"]?.stringValue ?? "",
            rotated: payload["rotated"]?.boolValue ?? false,
            stopped: payload["stopped"]?.stringValue
        )
    }
}
