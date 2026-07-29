import Foundation

/// Parses an artifact `updated_by` stamp into something legible: WHO revised
/// this — a cron job, an agent session, or a person on a device — instead of
/// the raw wire string. The gateway stamps `cron:<jobId>` for cron-run writes
/// and `session:<sessionId>` for agent-session writes; the app stamps
/// `user:<device>` / `app:<device>` for local writes. Older gateways emitted
/// `agent:<sessionId>` (with cron runs hiding inside a `cron_<jobId>_<ts>`
/// session id) — those parse too so history predating the stamp stays legible.
internal enum WriterRef: Equatable {
    case cron(jobID: String)
    case session(id: String)
    case user
    case gateway(detail: String)
    case other(raw: String)

    internal static func parse(_ raw: String) -> WriterRef? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else { return .other(raw: trimmed) }
        let prefix = trimmed[..<colon]
        let value = String(trimmed[trimmed.index(after: colon)...])
        switch prefix {
        case "cron":
            return .cron(jobID: value)
        case "session":
            return .session(id: value)
        case "agent":
            // Legacy stamp. Cron runs used a synthetic session id of the form
            // cron_<jobId>_<YYYYmmdd_HHMMSS> — surface those as the cron.
            if let jobID = cronJobID(fromLegacySessionID: value) {
                return .cron(jobID: jobID)
            }
            return value.isEmpty ? .other(raw: trimmed) : .session(id: value)
        case "user", "app":
            return .user
        case "gateway":
            return .gateway(detail: value)
        default:
            return .other(raw: trimmed)
        }
    }

    /// `cron_<jobId>_<YYYYmmdd>_<HHMMSS>` → jobId; nil when the shape doesn't match.
    private static func cronJobID(fromLegacySessionID id: String) -> String? {
        guard id.hasPrefix("cron_") else { return nil }
        let parts = id.split(separator: "_")
        // cron / jobId / date / time — the job id itself contains no "_".
        guard parts.count >= 3 else { return nil }
        let jobID = String(parts[1])
        return jobID.isEmpty ? nil : jobID
    }

    /// SF Symbol matching the writer kind.
    internal var icon: String {
        switch self {
        case .cron: return "clock.arrow.circlepath"
        case .session: return "sparkles"
        case .user: return "person.fill"
        case .gateway: return "server.rack"
        case .other: return "questionmark.circle"
        }
    }

    /// Short human label. Cron refs resolve through the provided name lookup
    /// (job id → display name) so the row reads "Nightly refresh", not a hash.
    internal func label(cronName: (String) -> String?) -> String {
        switch self {
        case .cron(let jobID):
            return cronName(jobID) ?? "cron \(jobID)"
        case .session(let id):
            return "agent session \(String(id.prefix(8)))"
        case .user:
            return "you"
        case .gateway(let detail):
            return detail.isEmpty ? "gateway" : "gateway (\(detail))"
        case .other(let raw):
            return raw
        }
    }
}
