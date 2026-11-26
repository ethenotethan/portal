import Foundation

/// Comments pinned to living artifacts, as the gateway holds them.
///
/// The gateway is the only copy: nothing is cached on disk, and every change
/// (this device's, another's, or the agent resolving a note) arrives as an
/// `artifact.comment.changed` event that refetches the artifact's list. A
/// separate observable from the artifact list, so a new comment republishes
/// only the views that show comments.
@MainActor
internal final class ArtifactCommentStore: ObservableObject {
    @Published internal private(set) var commentsByArtifact: [String: [ArtifactComment]] = [:]
    /// Why the last comment action did not land, for the pane to show.
    @Published internal private(set) var failure: String?

    private var client: (any ArtifactCommentGateway)?

    internal init() {}

    internal func setClient(_ client: (any ArtifactCommentGateway)?) {
        self.client = client
    }

    internal func comments(for artifactID: String) -> [ArtifactComment] {
        commentsByArtifact[artifactID] ?? []
    }

    internal func openCount(for artifactID: String) -> Int {
        comments(for: artifactID).filter { !$0.resolved }.count
    }

    /// Fetch an artifact's comments. An old gateway answers nil and the list
    /// stays empty; a transport error leaves what is already shown.
    internal func refresh(artifactID: String) async {
        guard let client else { return }
        do {
            guard let fetched = try await client.artifactCommentList(artifactID: artifactID) else { return }
            commentsByArtifact[artifactID] = fetched
        } catch {
            failure = Self.describe(error, doing: "load comments")
        }
    }

    /// Pin a new comment. Returns false when it was not stored, so the composer
    /// keeps the reader's words.
    internal func add(
        artifactID: String, artifactRev: Int, anchor: ArtifactCommentAnchor, body: String
    ) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard let client else {
            failure = "Not connected to a gateway."
            return false
        }
        do {
            guard let stored = try await client.artifactCommentAdd(
                artifactID: artifactID, artifactRev: artifactRev, anchor: anchor, body: text
            ) else {
                failure = "This gateway does not store artifact comments."
                return false
            }
            upsert(stored, artifactID: artifactID)
            failure = nil
            return true
        } catch {
            failure = Self.describe(error, doing: "save the comment")
            return false
        }
    }

    internal func setResolved(artifactID: String, commentID: String, resolved: Bool) async {
        guard let client else { return }
        do {
            if let stored = try await client.artifactCommentResolve(
                artifactID: artifactID, commentID: commentID, resolved: resolved
            ) {
                upsert(stored, artifactID: artifactID)
            }
            failure = nil
        } catch {
            failure = Self.describe(error, doing: resolved ? "resolve the comment" : "reopen the comment")
        }
    }

    internal func delete(artifactID: String, commentID: String) async {
        guard let client else { return }
        do {
            try await client.artifactCommentDelete(artifactID: artifactID, commentID: commentID)
            commentsByArtifact[artifactID]?.removeAll { $0.id == commentID }
            failure = nil
        } catch {
            failure = Self.describe(error, doing: "delete the comment")
        }
    }

    internal func clearFailure() {
        failure = nil
    }

    /// A comment changed on the gateway. Only artifacts whose comments are
    /// already on screen refetch; the rest load when they are opened.
    internal func remoteChange(artifactID: String) {
        guard commentsByArtifact[artifactID] != nil else { return }
        Task { await refresh(artifactID: artifactID) }
    }

    /// The artifact was deleted; the gateway dropped its comments with it.
    internal func forget(artifactID: String) {
        commentsByArtifact.removeValue(forKey: artifactID)
    }

    private func upsert(_ comment: ArtifactComment, artifactID: String) {
        var list = commentsByArtifact[artifactID] ?? []
        if let index = list.firstIndex(where: { $0.id == comment.id }) {
            list[index] = comment
        } else {
            list.append(comment)
        }
        commentsByArtifact[artifactID] = list
    }

    private static func describe(_ error: Error, doing action: String) -> String {
        "Couldn't \(action): \(error.localizedDescription)"
    }
}
