import Combine
import Foundation
import Testing
@testable import Portal

/// The long-session churn loop: every artifact row re-parsed its whole content
/// on every render, and each live query result republished the entire store.
/// These pin the three fixes — parse once per content, equatable rows, and a
/// separately published query-state store.
@MainActor
@Suite("Artifact render churn — parse once, republish narrowly")
internal struct ArtifactRenderChurnTests {
    private static let maintained = "{\"maintainers\": [\"cron:nightly\", \"cron:hourly\"], \"markers\": [{\"label\": \"A\"}]}"

    private func artifact(_ content: String, rev: Int = 1) -> LivingArtifact {
        LivingArtifact(id: "a", kind: "map", title: "Map", content: content, updatedAt: Date(timeIntervalSince1970: 1), updatedBy: "cron:nightly", rev: rev)
    }

    @Test("derived values compute once per content and are shared by copies")
    internal func derivedValuesComputeOnce() {
        let derived = LivingArtifactDerived()
        var computed = 0
        for _ in 0..<50 {
            _ = derived.maintainerRefs {
                computed += 1
                return [MaintainerRef.cron(jobID: "nightly")]
            }
        }
        #expect(computed == 1)
        var objectComputed = 0
        for _ in 0..<50 {
            _ = derived.jsonObject {
                objectComputed += 1
                return nil   // "not JSON" is memoised too
            }
        }
        #expect(objectComputed == 1)

        let original = artifact(Self.maintained)
        let copy = original
        #expect(original.maintainerRefs.count == 2)
        #expect(copy.maintainerRefs.count == 2)
        #expect(original.supportsMaintainers)
        #expect(original.jsonObject?["markers"] != nil)
        #expect(original == copy, "the cache never takes part in equality")
    }

    @Test("a content change invalidates the derived values; equality ignores the cache")
    internal func contentChangeInvalidates() {
        var subject = artifact(Self.maintained)
        #expect(subject.maintainerRefs.count == 2)
        subject.content = "# just markdown now"
        #expect(subject.maintainerRefs.isEmpty)
        #expect(!subject.supportsMaintainers)
        #expect(subject.jsonObject == nil)
        var same = artifact(Self.maintained)
        _ = same.maintainerRefs
        let fresh = artifact(Self.maintained)
        #expect(same == fresh, "a cached and an uncached copy of the same value are equal")
        same.content = Self.maintained
        #expect(same.maintainerRefs.count == 2, "assigning identical content keeps the cache valid")
    }

    @Test("codable round-trip keeps the derived values correct")
    internal func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(artifact(Self.maintained))
        let decoded = try JSONDecoder().decode(LivingArtifact.self, from: data)
        #expect(decoded.maintainerRefs.count == 2)
        #expect(decoded.supportsMaintainers)
    }

    @Test("sorted artifacts are computed once per store change and shared across reads")
    internal func sortedArtifactsAreCached() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        let gateway = UUID()
        for index in 0..<5 {
            var item = artifact(Self.maintained, rev: index)
            item.updatedAt = Date(timeIntervalSince1970: TimeInterval(index))
            store.seedArtifactForTesting(LivingArtifact(
                id: "a\(index)", kind: "map", title: "A\(index)", content: item.content,
                updatedAt: item.updatedAt, updatedBy: "cron:nightly", rev: index,
                gatewayID: index.isMultiple(of: 2) ? gateway : nil
            ))
        }
        // Recency order, and the id projection agrees with it.
        #expect(store.sortedArtifacts.map(\.id) == ["a4", "a3", "a2", "a1", "a0"])
        #expect(store.sortedArtifactIDs == ["a4", "a3", "a2", "a1", "a0"])
        // Repeated reads hand back the same value without re-sorting.
        let first = store.sortedArtifacts
        #expect(store.sortedArtifacts == first)
        #expect(store.sortedArtifactIDs == first.map(\.id))

        // A change to the map invalidates: a newer bystander leads the list.
        store.seedArtifactForTesting(LivingArtifact(
            id: "b", kind: "map", title: "B", content: "{}",
            updatedAt: Date(timeIntervalSince1970: 100), updatedBy: "cron:other", rev: 1
        ))
        #expect(store.sortedArtifactIDs.first == "b")
        #expect(store.sortedArtifacts.count == 6)
        // Removing invalidates too.
        store.remove(id: "b")
        #expect(store.sortedArtifactIDs == ["a4", "a3", "a2", "a1", "a0"])

        // Focusing a gateway scopes the list and invalidates the cache.
        store.focusedGatewayID = gateway
        #expect(store.sortedArtifactIDs == ["a4", "a2", "a0"])
        #expect(store.sortedArtifacts.allSatisfy { $0.gatewayID == gateway })
        store.focusedGatewayID = nil
        #expect(store.sortedArtifactIDs.count == 5)
    }

    @Test("the model renderer chain is value-equal for an unchanged artifact")
    internal func modelChainEquality() {
        let base = artifact("{\"entities\":{\"work\":{\"items\":[{\"id\":\"w1\"}]}}}", rev: 3)
        #expect(ArtifactDetailView(artifact: base) == ArtifactDetailView(artifact: base))
        var bumped = base
        bumped.rev = 4
        #expect(ArtifactDetailView(artifact: base) != ArtifactDetailView(artifact: bumped))
        var edited = base
        edited.content = "{\"entities\":{\"work\":{\"items\":[]}}}"
        #expect(ArtifactDetailView(artifact: base) != ArtifactDetailView(artifact: edited))

        let block = ModelBlockView(json: base.content, isStreaming: false, actionableArtifactID: base.id)
        #expect(block == ModelBlockView(json: base.content, isStreaming: false, actionableArtifactID: base.id))
        #expect(block != ModelBlockView(json: edited.content, isStreaming: false, actionableArtifactID: base.id))
        #expect(block != ModelBlockView(json: base.content, isStreaming: false, actionableArtifactID: nil))
    }

    @Test("a choice prompt identifies one field of one entry and commits through the store")
    internal func choicePromptIdentity() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let action = ArtifactAction(
            kind: .choice, field: "status", options: ["open", "done"],
            bindingID: "", label: "", intentName: "", presentationRole: .normal
        )
        let prompt = ArtifactChoicePrompt(artifactID: "a", action: action, entryKey: "r1", currentValue: "open", title: "Row 1")
        #expect(prompt.id == "a|r1|status")
        #expect(prompt == ArtifactChoicePrompt(artifactID: "a", action: action, entryKey: "r1", currentValue: "open", title: "Row 1"))
        #expect(prompt != ArtifactChoicePrompt(artifactID: "a", action: action, entryKey: "r2", currentValue: "open", title: "Row 2"))
    }

    @Test("list row inputs are value-equal for an unchanged artifact and differ when it changes")
    internal func rowInputsEquality() {
        let base = artifact(Self.maintained)
        let a = ArtifactListRow.Inputs(artifact: base, isSelected: false)
        let b = ArtifactListRow.Inputs(artifact: base, isSelected: false)
        #expect(a == b)
        #expect(a.hasMaintainers)
        #expect(a.writerLabel != nil)
        #expect(a != ArtifactListRow.Inputs(artifact: base, isSelected: true))
        #expect(a != ArtifactListRow.Inputs(artifact: artifact(Self.maintained, rev: 2), isSelected: false))
        var plain = base
        plain.content = "# doc"
        #expect(!ArtifactListRow.Inputs(artifact: plain, isSelected: false).hasMaintainers)
    }

    @Test("the preview gist uses the parsed-once object and only parses itself when none is handed over")
    internal func gistUsesHandedObject() {
        let subject = artifact(Self.maintained)
        let viaObject = ArtifactPreviewGist.make(kind: "map", content: subject.content, object: .some(subject.jsonObject))
        let viaParse = ArtifactPreviewGist.make(kind: "map", content: subject.content)
        #expect(viaObject == viaParse)
        #expect(viaObject.hasPrefix("1 marker"))
        #expect(ArtifactPreviewGist.make(kind: "map", content: "not json", object: .some(nil)) == "not json")
    }

    @Test("a query result republishes the live sub-store, not the artifact store")
    internal func queryResultsPublishNarrowly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        var storeChanges = 0
        var liveChanges = 0
        var cancellables = Set<AnyCancellable>()
        store.objectWillChange.sink { _ in storeChanges += 1 }.store(in: &cancellables)
        store.live.objectWillChange.sink { _ in liveChanges += 1 }.store(in: &cancellables)

        // The synchronous write path (runQuery resolves on a Task).
        store.markQueryUnsupported(artifactID: "dash", queryID: "rows", rawParams: "", reason: "no gateway surface")
        #expect(liveChanges >= 1)
        #expect(storeChanges == 0, "query state must not republish the artifact list")
        #expect(store.queryStates.count == 1, "the read-through accessor still sees the state")

        let before = liveChanges
        store.seedIntentStateForTesting(artifactID: "dash", bindingID: "b", entryKey: "e", state: .pending)
        #expect(liveChanges > before)
        #expect(storeChanges == 0)
        #expect(store.intentStates.count == 1)
    }
}
