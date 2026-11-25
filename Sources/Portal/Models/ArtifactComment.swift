import Foundation

/// Where a comment's pin sits on a rendered artifact: the element it was
/// dropped on, the position inside that element's box, and what the element
/// showed. The text is what finds the pin again after the markup around it
/// changes. An anchor with no selector is a comment on the artifact as a whole.
internal struct ArtifactCommentAnchor: Equatable, Sendable {
    internal static let maxSelectorBytes = 512
    internal static let maxTextCharacters = 280

    internal var selector: String = ""
    /// Fractions (0–1) of the element's width and height.
    internal var x: Double = 0.5
    internal var y: Double = 0.5
    internal var text: String = ""

    internal var isWholeArtifact: Bool { selector.isEmpty }

    /// The `anchor` param of `artifact.comment.add`.
    internal var wire: [String: AnyCodable] {
        guard !isWholeArtifact else { return [:] }
        var fields: [String: AnyCodable] = [
            "selector": AnyCodable(selector), "x": AnyCodable(x), "y": AnyCodable(y),
        ]
        if !text.isEmpty { fields["text"] = AnyCodable(text) }
        return fields
    }

    internal static func from(_ d: [String: AnyCodable]?) -> ArtifactCommentAnchor {
        ArtifactCommentAnchor(
            selector: d?["selector"]?.stringValue ?? "",
            x: d?["x"]?.doubleValue ?? 0.5,
            y: d?["y"]?.doubleValue ?? 0.5,
            text: d?["text"]?.stringValue ?? ""
        )
    }
}

/// A note the reader pinned to a living artifact. Stored by the gateway beside
/// the artifact, never inside its content, so the agent rewriting an HTML
/// document does not erase it. The agent reads the open ones before it edits.
internal struct ArtifactComment: Identifiable, Equatable, Sendable {
    internal let id: String
    internal let artifactID: String
    /// The artifact revision the reader was looking at when they wrote it.
    internal let rev: Int
    internal let anchor: ArtifactCommentAnchor
    internal let author: String
    internal let body: String
    internal let createdAt: Date
    internal let resolved: Bool
    /// Who marked it addressed: `agent:<session>` or `app:<device>`.
    internal let resolvedBy: String

    internal var resolvedByAgent: Bool { resolved && resolvedBy.hasPrefix("agent") }

    internal static func from(_ d: [String: AnyCodable]?) -> ArtifactComment? {
        guard let d, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ArtifactComment(
            id: id,
            artifactID: d["artifact_id"]?.stringValue ?? "",
            rev: d["rev"]?.intValue ?? 0,
            anchor: ArtifactCommentAnchor.from(d["anchor"]?.dictionaryValue),
            author: d["author"]?.stringValue ?? "",
            body: d["body"]?.stringValue ?? "",
            createdAt: d["created_at"]?.stringValue.flatMap(LivingArtifact.parseISO) ?? Date(),
            resolved: d["resolved"]?.boolValue ?? false,
            resolvedBy: d["resolved_by"]?.stringValue ?? ""
        )
    }
}

/// The slice of the gateway `ArtifactCommentStore` depends on, so tests drive
/// the store with a fake. A nil result means the gateway has no
/// `artifact.comment.*` surface.
@MainActor
internal protocol ArtifactCommentGateway: AnyObject, Sendable {
    func artifactCommentList(artifactID: String) async throws -> [ArtifactComment]?
    func artifactCommentAdd(
        artifactID: String, artifactRev: Int, anchor: ArtifactCommentAnchor, body: String
    ) async throws -> ArtifactComment?
    func artifactCommentResolve(
        artifactID: String, commentID: String, resolved: Bool
    ) async throws -> ArtifactComment?
    func artifactCommentDelete(artifactID: String, commentID: String) async throws
}
