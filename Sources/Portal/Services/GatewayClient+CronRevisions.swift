import Foundation

// MARK: - cron.manage action "revisions"

/// Hermes gateway: one job's definition history, when the harness records it.
extension GatewayClient {

    /// The gateway's refusal for an action it does not know; an older harness
    /// answers `revisions` with it, which the card shows as "not available on
    /// this gateway" rather than as an empty history.
    internal static let unknownCronActionCode = 4016

    internal func cronJobRevisions(id: String, limit: Int = 50, offset: Int = 0) async throws -> CronJobRevisionsPage {
        let response = try await call("cron.manage", params: [
            "action": AnyCodable("revisions"),
            "name": AnyCodable(id),
            "limit": AnyCodable(limit),
            "offset": AnyCodable(offset),
        ])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("cron.manage revisions missing result")
        }
        return Self.cronJobRevisionsPage(from: result, jobID: id, requestedLimit: limit, requestedOffset: offset)
    }

    // MARK: - Decoding

    /// Every field but `id` is optional; a revision without an id is dropped
    /// rather than defaulted into existence, the same tolerance the changeset
    /// page decodes with.
    nonisolated internal static func cronJobRevisionsPage(
        from value: AnyCodable,
        jobID: String,
        requestedLimit: Int,
        requestedOffset: Int
    ) -> CronJobRevisionsPage {
        let dict = value.dictionaryValue ?? [:]
        let revisions = (dict["revisions"]?.arrayValue ?? []).compactMap(cronJobRevision(from:))
        return CronJobRevisionsPage(
            jobID: dict["job_id"]?.stringValue ?? jobID,
            jobName: dict["job_name"]?.stringValue,
            revisions: revisions,
            total: dict["total"]?.intValue ?? revisions.count,
            limit: dict["limit"]?.intValue ?? requestedLimit,
            offset: dict["offset"]?.intValue ?? requestedOffset
        )
    }

    nonisolated internal static func cronJobRevision(from item: AnyCodable) -> CronJobRevision? {
        guard let d = item.dictionaryValue,
              let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        let definition: [String: AnyCodable]?
        if let raw = d["definition"], let dictionary = raw.dictionaryValue {
            definition = dictionary
        } else {
            definition = nil
        }
        return CronJobRevision(
            id: id,
            timestamp: d["timestamp"]?.stringValue ?? "",
            action: d["action"]?.stringValue ?? "",
            actor: CronChangesetActor(raw: d["actor"]?.stringValue ?? ""),
            summary: d["summary"]?.stringValue ?? "",
            gitCommit: d["git_commit"]?.stringValue ?? "",
            definition: definition,
            changes: (d["changes"]?.arrayValue ?? []).compactMap(cronDefinitionChange(from:)),
            // Absent means an old harness that always recorded definitions when
            // it served this action at all; only an explicit false marks a
            // pre-definition row.
            definitionRecorded: d["definition_recorded"]?.boolValue ?? true
        )
    }

    nonisolated internal static func cronDefinitionChange(from item: AnyCodable) -> CronDefinitionChange? {
        guard let d = item.dictionaryValue,
              let field = d["field"]?.stringValue, !field.isEmpty else { return nil }
        let before = d["before"]
        let after = d["after"]
        return CronDefinitionChange(
            field: field,
            before: (before.map(isNull) ?? true) ? nil : before,
            after: (after.map(isNull) ?? true) ? nil : after
        )
    }

    nonisolated private static func isNull(_ value: AnyCodable) -> Bool {
        if case .null = value { return true }
        return false
    }
}
