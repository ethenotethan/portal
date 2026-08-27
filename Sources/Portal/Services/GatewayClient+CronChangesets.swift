import Foundation

// MARK: - cron.changesets / cron.changeset_diff

/// Hermes gateway: the recorded cron configuration history, when it has one.
///
/// Conformance is unconditional and deliberately says nothing about whether a
/// given gateway implements these methods — that's `CronChangesetFeed`'s job,
/// from the error the gateway returns. See `CronChangesetSource`.
extension GatewayClient: CronChangesetSource {

    internal func cronChangesets(
        limit: Int = 50,
        offset: Int = 0,
        since: String? = nil,
        until: String? = nil,
        job: String? = nil
    ) async throws -> CronChangesetsPage {
        var params: [String: AnyCodable] = [
            "limit": AnyCodable(limit),
            "offset": AnyCodable(offset),
        ]
        if let since { params["since"] = AnyCodable(since) }
        if let until { params["until"] = AnyCodable(until) }
        if let job { params["job"] = AnyCodable(job) }

        let response = try await call("cron.changesets", params: params)
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("cron.changesets missing result")
        }
        return Self.cronChangesetsPage(from: result, requestedLimit: limit, requestedOffset: offset)
    }

    internal func cronChangesetDiff(id: String) async throws -> CronChangesetDiff {
        let response = try await call("cron.changeset_diff", params: ["id": AnyCodable(id)])
        if let error = response.error {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        guard let result = response.result else {
            throw GatewayError.invalidResponse("cron.changeset_diff missing result")
        }
        return try Self.cronChangesetDiff(from: result)
    }

    // MARK: - Decoding

    /// Every field is optional except `id`, and a row missing one is dropped
    /// rather than defaulted into existence — the same tolerance
    /// `wikiChangesets` decodes with, for the same reason: this app cannot
    /// require a gateway to have shipped the newest field before its history is
    /// readable at all.
    nonisolated internal static func cronChangesetsPage(
        from value: AnyCodable,
        requestedLimit: Int,
        requestedOffset: Int
    ) -> CronChangesetsPage {
        let dict = value.dictionaryValue ?? [:]
        let changesets = (dict["changesets"]?.arrayValue ?? []).compactMap(cronChangeset(from:))
        return CronChangesetsPage(
            changesets: changesets,
            total: dict["total"]?.intValue ?? changesets.count,
            limit: dict["limit"]?.intValue ?? requestedLimit,
            offset: dict["offset"]?.intValue ?? requestedOffset
        )
    }

    nonisolated internal static func cronChangeset(from item: AnyCodable) -> CronChangeset? {
        guard let d = item.dictionaryValue,
              let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        // An empty parent digest is the wire's way of saying "none", and it has
        // to arrive as nil: `""` would later be compared against a real digest
        // and chain this change to a revision that doesn't exist.
        let parent = d["parent_digest"]?.stringValue
        return CronChangeset(
            id: id,
            timestamp: d["timestamp"]?.stringValue ?? "",
            action: d["action"]?.stringValue ?? "",
            job: d["job"]?.stringValue ?? "",
            digest: d["digest"]?.stringValue ?? "",
            parentDigest: (parent?.isEmpty ?? true) ? nil : parent,
            actor: CronChangesetActor(raw: d["actor"]?.stringValue ?? ""),
            summary: d["summary"]?.stringValue ?? "",
            provenance: CronChangesetProvenance.decode(
                d[CronChangesetProvenance.wireKey]?.arrayValue?.compactMap(\.stringValue)
            ),
            gitCommit: d["git_commit"]?.stringValue ?? ""
        )
    }

    /// Decode the two graphs, tolerating either being absent.
    ///
    /// A graph that's present but malformed throws rather than decoding to
    /// nothing: "the gateway didn't send a before" and "the before it sent
    /// couldn't be read" lead to different words on screen, and only the first
    /// one is a normal state.
    nonisolated internal static func cronChangesetDiff(from value: AnyCodable) throws -> CronChangesetDiff {
        let dict = value.dictionaryValue ?? [:]
        let text = dict["diff"]?.stringValue ?? dict["unified"]?.stringValue
        return CronChangesetDiff(
            before: try dict["before"].map(CronGraph.decodeGatewayValue),
            after: try dict["after"].map(CronGraph.decodeGatewayValue),
            unifiedText: (text?.isEmpty ?? true) ? nil : text
        )
    }
}
