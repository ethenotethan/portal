import Foundation
import Testing
@testable import Portal

// ArtifactCommentStore against a scriptable gateway: what the pane shows after
// each action, and what it says when one does not land.

@MainActor
private final class FakeCommentGateway: ArtifactCommentGateway {
    internal var stored: [String: [ArtifactComment]] = [:]
    internal var supported = true
    internal var failure: Error?
    internal private(set) var listCalls: [String] = []
    internal private(set) var added: [(artifactID: String, rev: Int, anchor: ArtifactCommentAnchor, body: String)] = []

    private func make(_ id: String, artifactID: String, rev: Int, anchor: ArtifactCommentAnchor,
                      body: String, resolved: Bool = false) -> ArtifactComment {
        ArtifactComment(
            id: id, artifactID: artifactID, rev: rev, anchor: anchor, author: "app:test", body: body,
            createdAt: Date(timeIntervalSince1970: 0), resolved: resolved, resolvedBy: resolved ? "app:test" : "")
    }

    internal func artifactCommentList(artifactID: String) async throws -> [ArtifactComment]? {
        listCalls.append(artifactID)
        if let failure { throw failure }
        return supported ? (stored[artifactID] ?? []) : nil
    }

    internal func artifactCommentAdd(
        artifactID: String, artifactRev: Int, anchor: ArtifactCommentAnchor, body: String
    ) async throws -> ArtifactComment? {
        if let failure { throw failure }
        guard supported else { return nil }
        added.append((artifactID, artifactRev, anchor, body))
        let comment = make("c-\(added.count)", artifactID: artifactID, rev: artifactRev, anchor: anchor, body: body)
        stored[artifactID, default: []].append(comment)
        return comment
    }

    internal func artifactCommentResolve(
        artifactID: String, commentID: String, resolved: Bool
    ) async throws -> ArtifactComment? {
        if let failure { throw failure }
        guard let index = stored[artifactID]?.firstIndex(where: { $0.id == commentID }),
              let old = stored[artifactID]?[index] else { return nil }
        let updated = make(old.id, artifactID: artifactID, rev: old.rev, anchor: old.anchor, body: old.body, resolved: resolved)
        stored[artifactID]?[index] = updated
        return updated
    }

    internal func artifactCommentDelete(artifactID: String, commentID: String) async throws {
        if let failure { throw failure }
        stored[artifactID]?.removeAll { $0.id == commentID }
    }
}

private struct Offline: LocalizedError {
    internal var errorDescription: String? { "the gateway is offline" }
}

@Suite("Artifact comment store")
@MainActor
internal struct ArtifactCommentStoreTests {
    private let anchor = ArtifactCommentAnchor(selector: "body > p", x: 0.3, y: 0.6, text: "Totals")

    private func connected() -> (ArtifactCommentStore, FakeCommentGateway) {
        let gateway = FakeCommentGateway()
        let store = ArtifactCommentStore()
        store.setClient(gateway)
        return (store, gateway)
    }

    @Test("A saved comment is sent trimmed, pinned to the revision on screen, and shown at once")
    internal func addStoresAndShows() async {
        let (store, gateway) = connected()
        let saved = await store.add(artifactID: "report", artifactRev: 7, anchor: anchor, body: "  Stale totals.\n")
        #expect(saved)
        #expect(gateway.added.first?.body == "Stale totals.")
        #expect(gateway.added.first?.rev == 7)
        #expect(gateway.added.first?.anchor == anchor)
        #expect(store.comments(for: "report").map(\.body) == ["Stale totals."])
        #expect(store.openCount(for: "report") == 1)
        #expect(store.failure == nil)
    }

    @Test("An empty note is never sent")
    internal func emptyNoteIsNotSent() async {
        let (store, gateway) = connected()
        #expect(await store.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: " \n ") == false)
        #expect(gateway.added.isEmpty)
    }

    @Test("A save that does not land says why and keeps the list unchanged")
    internal func failedSaveExplains() async {
        let (store, gateway) = connected()
        gateway.failure = Offline()
        #expect(await store.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: "note") == false)
        #expect(store.failure == "Couldn't save the comment: the gateway is offline")
        #expect(store.comments(for: "report").isEmpty)

        gateway.failure = nil
        gateway.supported = false
        #expect(await store.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: "note") == false)
        #expect(store.failure == "This gateway does not store artifact comments.")

        let offline = ArtifactCommentStore()
        #expect(await offline.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: "note") == false)
        #expect(offline.failure == "Not connected to a gateway.")
        offline.clearFailure()
        #expect(offline.failure == nil)
    }

    @Test("Resolving, reopening and deleting update the open count")
    internal func resolveReopenDelete() async {
        let (store, _) = connected()
        _ = await store.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: "one")
        _ = await store.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: "two")

        await store.setResolved(artifactID: "report", commentID: "c-1", resolved: true)
        #expect(store.openCount(for: "report") == 1)
        #expect(store.comments(for: "report").first?.resolved == true)

        await store.setResolved(artifactID: "report", commentID: "c-1", resolved: false)
        #expect(store.openCount(for: "report") == 2)

        await store.delete(artifactID: "report", commentID: "c-2")
        #expect(store.comments(for: "report").map(\.id) == ["c-1"])
    }

    @Test("A failed resolve or delete is reported and changes nothing")
    internal func failedActionsAreReported() async {
        let (store, gateway) = connected()
        _ = await store.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: "one")
        gateway.failure = Offline()

        await store.setResolved(artifactID: "report", commentID: "c-1", resolved: true)
        #expect(store.failure == "Couldn't resolve the comment: the gateway is offline")
        await store.delete(artifactID: "report", commentID: "c-1")
        #expect(store.failure == "Couldn't delete the comment: the gateway is offline")
        #expect(store.comments(for: "report").map(\.resolved) == [false])
    }

    @Test("Refresh shows what the gateway holds; an old gateway leaves the list empty")
    internal func refreshLoads() async {
        let (store, gateway) = connected()
        _ = try? await gateway.artifactCommentAdd(artifactID: "report", artifactRev: 2, anchor: anchor, body: "from another device")
        await store.refresh(artifactID: "report")
        #expect(store.comments(for: "report").map(\.body) == ["from another device"])

        gateway.supported = false
        await store.refresh(artifactID: "other")
        #expect(store.commentsByArtifact["other"] == nil)

        gateway.failure = Offline()
        await store.refresh(artifactID: "report")
        #expect(store.failure == "Couldn't load comments: the gateway is offline")
        #expect(store.comments(for: "report").count == 1)
    }

    @Test("A remote change refetches only an artifact whose comments are on screen")
    internal func remoteChangeRefetchesLoadedArtifacts() async {
        let (store, gateway) = connected()
        store.remoteChange(artifactID: "never-opened")
        await Task.yield()
        #expect(gateway.listCalls.isEmpty)

        await store.refresh(artifactID: "report")
        _ = try? await gateway.artifactCommentAdd(artifactID: "report", artifactRev: 2, anchor: anchor, body: "agent resolved one")
        store.remoteChange(artifactID: "report")
        for _ in 0..<20 where store.comments(for: "report").isEmpty { await Task.yield() }
        #expect(store.comments(for: "report").map(\.body) == ["agent resolved one"])
    }

    @Test("Deleting the artifact forgets its comments")
    internal func forgetDropsComments() async {
        let (store, _) = connected()
        _ = await store.add(artifactID: "report", artifactRev: 1, anchor: anchor, body: "one")
        store.forget(artifactID: "report")
        #expect(store.commentsByArtifact["report"] == nil)
    }
}
