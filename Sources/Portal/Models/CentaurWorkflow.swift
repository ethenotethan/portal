import Foundation

/// Centaur control-plane workflow surfaces (services/api-rs):
/// `GET /api/workflows/runs`, `GET /api/workflows/runs/{id}`,
/// `POST /api/workflows/runs/{id}/cancel`, `GET /api/workflows/schedules`.
/// The Centaur analogue of Hermes cron: schedules are the standing
/// definitions, runs the execution history.
struct CentaurWorkflowRun: Decodable, Identifiable {
    let runID: String
    let taskID: String
    let workflowName: String
    let status: String
    let input: AnyCodable?
    let result: AnyCodable?
    let failure: AnyCodable?
    let attempts: Int
    let createdAt: Date?
    let updatedAt: Date?

    var id: String { runID }

    /// Terminal states can't be cancelled.
    var isActive: Bool {
        switch status.lowercased() {
        case "completed", "failed", "cancelled", "canceled": return false
        default: return true
        }
    }

    /// Human summary of a failure payload, if any.
    var failureSummary: String? {
        guard let failure else { return nil }
        if let s = failure.stringValue { return s }
        if let d = failure.dictionaryValue {
            return d["message"]?.stringValue ?? d["error"]?.stringValue ?? failure.displayString
        }
        return failure.displayString
    }

    private enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case taskID = "task_id"
        case workflowName = "workflow_name"
        case status, input, result, failure, attempts
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runID = try c.decode(String.self, forKey: .runID)
        taskID = try c.decodeIfPresent(String.self, forKey: .taskID) ?? ""
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName) ?? "workflow"
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        input = try c.decodeIfPresent(AnyCodable.self, forKey: .input)
        result = try c.decodeIfPresent(AnyCodable.self, forKey: .result)
        failure = try c.decodeIfPresent(AnyCodable.self, forKey: .failure)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        // RFC 3339 timestamps.
        createdAt = (try? c.decodeIfPresent(String.self, forKey: .createdAt)).flatMap(Self.parseDate)
        updatedAt = (try? c.decodeIfPresent(String.self, forKey: .updatedAt)).flatMap(Self.parseDate)
    }

    private static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        // Fractional seconds first (the server emits them), then plain.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: s) { return date }
        return ISO8601DateFormatter().date(from: s)
    }
}

struct CentaurWorkflowSchedule: Decodable, Identifiable {
    let scheduleID: String
    let workflowName: String
    let kind: AnyCodable?
    let timezone: String
    let enabled: Bool

    var id: String { scheduleID }

    /// Interval in seconds when the schedule is interval-kind, nil for cron.
    /// Live deployments emit {"type": "interval", "interval_seconds": N};
    /// upstream source also has {"interval": {"secs": N}} — accept both.
    var intervalSeconds: Int? {
        guard let d = kind?.dictionaryValue else { return nil }
        if let secs = d["interval_seconds"]?.intValue { return secs }
        if let secs = d["interval"]?.dictionaryValue?["secs"]?.intValue { return secs }
        return nil
    }

    /// Cron expression when cron-kind, nil for interval. Accepts the live
    /// {"type": "cron", "cron": "expr"} and upstream {"cron": {"expr": …}}.
    var cronExpression: String? {
        guard let d = kind?.dictionaryValue else { return nil }
        if let expr = d["cron"]?.stringValue { return expr }
        if let expr = d["cron"]?.dictionaryValue?["expr"]?.stringValue { return expr }
        return nil
    }

    /// Short human cadence: "every 5m", "cron 0 9 * * 1-5", or "manual".
    var kindLabel: String {
        if let secs = intervalSeconds {
            return "every " + Duration.seconds(secs).formatted(.units(width: .narrow, maximumUnitCount: 2))
        }
        if let expr = cronExpression {
            return "cron \(expr)"
        }
        guard let d = kind?.dictionaryValue else { return kind?.stringValue ?? "manual" }
        return d["type"]?.stringValue ?? d.keys.sorted().joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey {
        case scheduleID = "schedule_id"
        case workflowName = "workflow_name"
        case kind, timezone, enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scheduleID = try c.decode(String.self, forKey: .scheduleID)
        workflowName = try c.decodeIfPresent(String.self, forKey: .workflowName) ?? "workflow"
        kind = try c.decodeIfPresent(AnyCodable.self, forKey: .kind)
        timezone = try c.decodeIfPresent(String.self, forKey: .timezone) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
