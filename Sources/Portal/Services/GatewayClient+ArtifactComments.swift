import Foundation

// Client surface for comments pinned to a living artifact
// (`artifact.comment.*`). Reads retry across a reconnect; writes use a plain
// `call`, because a blindly re-sent `add` would pin the same note twice.

extension GatewayClient: ArtifactCommentGateway {
    /// Every comment on an artifact, oldest first. Nil when the gateway has no
    /// `artifact.comment` surface.
    internal func artifactCommentList(artifactID: String) async throws -> [ArtifactComment]? {
        let response = try await callWithRetry("artifact.comment.list", params: [
            "artifact_id": AnyCodable(artifactID),
        ])
        if let error = response.error {
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        let rows = response.result?.dictionaryValue?["comments"]?.arrayValue ?? []
        return rows.compactMap { ArtifactComment.from($0.dictionaryValue) }
    }

    /// Pin a comment written against `artifactRev`, attributed to this device.
    internal func artifactCommentAdd(
        artifactID: String, artifactRev: Int, anchor: ArtifactCommentAnchor, body: String
    ) async throws -> ArtifactComment? {
        var params: [String: AnyCodable] = [
            "artifact_id": AnyCodable(artifactID),
            "artifact_rev": AnyCodable(artifactRev),
            "body": AnyCodable(body),
            "author": AnyCodable(Self.commentActor),
        ]
        if !anchor.isWholeArtifact { params["anchor"] = .dictionary(anchor.wire) }
        return try await commentResult(call("artifact.comment.add", params: params))
    }

    internal func artifactCommentResolve(
        artifactID: String, commentID: String, resolved: Bool
    ) async throws -> ArtifactComment? {
        try await commentResult(call("artifact.comment.resolve", params: [
            "artifact_id": AnyCodable(artifactID),
            "comment_id": AnyCodable(commentID),
            "resolved": AnyCodable(resolved),
            "resolved_by": AnyCodable(Self.commentActor),
        ]))
    }

    internal func artifactCommentDelete(artifactID: String, commentID: String) async throws {
        let response = try await call("artifact.comment.delete", params: [
            "artifact_id": AnyCodable(artifactID),
            "comment_id": AnyCodable(commentID),
        ])
        // Already gone is the outcome the caller wanted.
        if let error = response.error, error.code != 4004 {
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
    }

    private static var commentActor: String { "app:\(SessionMetaSyncService.deviceID.prefix(8))" }

    private func commentResult(_ response: JSONRPCResponse) throws -> ArtifactComment? {
        if let error = response.error {
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return ArtifactComment.from(response.result?.dictionaryValue?["comment"]?.dictionaryValue)
    }
}
