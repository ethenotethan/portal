import Combine
import Foundation
import Testing
@testable import Portal

/// A gateway that answers `artifact.categorize` and nothing else of interest.
@MainActor
private final class FakeFolderGateway: ArtifactGateway {
    let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()

    var categorizeError: Error?
    /// The spelling the gateway answers with (nil = echo what was sent).
    var storedSpelling: String?
    var listed: [LivingArtifact]?
    var fetched: LivingArtifact?
    private(set) var categorizeCalls: [(id: String, category: String)] = []

    func artifactCategorize(id: String, category: String) async throws -> LivingArtifact? {
        categorizeCalls.append((id, category))
        if let categorizeError { throw categorizeError }
        return LivingArtifact(
            id: id, kind: "markdown", title: "", content: "",
            updatedAt: Date(timeIntervalSince1970: 0), updatedBy: "test", rev: 3,
            category: storedSpelling ?? category)
    }

    func artifactGet(id: String) async throws -> LivingArtifact? { fetched }
    func artifactList() async throws -> [LivingArtifact]? { listed }
    func artifactSet(
        id: String, kind: String, content: String, title: String?, replace: Bool
    ) async throws -> LivingArtifact? { nil }
    func artifactDelete(id: String) async throws {}
    func artifactActionInvoke(
        artifactID: String, artifactRev: Int, bindingID: String,
        entityRef: String, idempotencyKey: String
    ) async throws -> ArtifactActionInvokeResult? { nil }
    func artifactActionConfirm(
        artifactID: String, challenge: String
    ) async throws -> ArtifactActionInvokeResult? { nil }
    func artifactActionLog(
        artifactID: String, bindingID: String?, limit: Int
    ) async throws -> [[String: AnyCodable]]? { nil }
    func artifactQueryInvoke(
        artifactID: String, artifactRev: Int, queryID: String,
        params: [String: AnyCodable], cursor: String?
    ) async throws -> ArtifactQueryResult? { nil }
    func artifactQuerySubscribe(
        artifactID: String, artifactRev: Int, queryID: String,
        params: [String: AnyCodable]
    ) async throws -> ArtifactQueryResult? { nil }
    func artifactQueryUnsubscribe(handle: String) async throws {}
}

private struct Refused: Error {}

@Suite("Artifact folders")
@MainActor
internal struct ArtifactFolderTests {

    private func artifact(_ id: String, category: String = "", rev: Int = 3) -> LivingArtifact {
        LivingArtifact(
            id: id, kind: "markdown", title: id, content: "# \(id)",
            updatedAt: Date(timeIntervalSince1970: 0), updatedBy: "test", rev: rev,
            category: category)
    }

    private func makeStore(_ artifacts: [LivingArtifact]) -> (ArtifactStore, FakeFolderGateway) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("artifact-folder-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        artifacts.forEach(store.seedArtifactForTesting)
        let gateway = FakeFolderGateway()
        store.injectClientForTesting(gateway)
        return (store, gateway)
    }

    /// Let the store's detached categorize round-trip settle.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Index

    @Test("Folders are counted, sorted by name, and case-insensitive")
    internal func indexGroupsFolders() {
        let index = ArtifactFolderIndex(categories: ["Travel", "research", "", "Research", "travel", ""])
        #expect(index.folders == [
            .init(name: "research", count: 2),
            .init(name: "Travel", count: 2),
        ])
        #expect(index.unfiledCount == 2)
        #expect(index.totalCount == 6)
        #expect(!index.isEmpty)
    }

    @Test("No filed artifact means no folders and no strip")
    internal func indexWithoutFolders() {
        let index = ArtifactFolderIndex(categories: ["", ""])
        #expect(index.isEmpty)
        #expect(index.resolve(.unfiled) == .all)
    }

    @Test("A remembered folder that emptied falls back to everything")
    internal func resolveFallsBack() {
        let index = ArtifactFolderIndex(categories: ["Travel", ""])
        #expect(index.resolve(.folder("travel")) == .folder("Travel"))
        #expect(index.resolve(.folder("Gone")) == .all)
        #expect(index.resolve(.unfiled) == .unfiled)
        #expect(ArtifactFolderIndex(categories: ["Travel"]).resolve(.unfiled) == .all)
    }

    @Test("Filtering keeps order and matches the selection")
    internal func filtering() {
        let all = [artifact("a", category: "Travel"), artifact("b"), artifact("c", category: "travel")]
        #expect(all.filed(under: .all).map(\.id) == ["a", "b", "c"])
        #expect(all.filed(under: .folder("Travel")).map(\.id) == ["a", "c"])
        #expect(all.filed(under: .unfiled).map(\.id) == ["b"])
    }

    @Test("Folder names normalize the way the gateway stores them")
    internal func normalize() {
        #expect(ArtifactFolderIndex.normalize("  Deep \t  Research\n") == "Deep Research")
        #expect(ArtifactFolderIndex.normalize("   ").isEmpty)
        #expect(ArtifactFolderIndex.normalize(String(repeating: "x", count: 80)).count == 64)
    }

    @Test("The selection round-trips through its stored string")
    internal func selectionRawValue() {
        for selection in [ArtifactFolderSelection.all, .unfiled, .folder("Deep Research"), .folder("a:b")] {
            #expect(ArtifactFolderSelection(rawValue: selection.rawValue) == selection)
        }
        #expect(ArtifactFolderSelection(rawValue: "nonsense") == .all)
        #expect(ArtifactFolderSelection(rawValue: "folder:") == .all)
    }

    // MARK: - Record

    @Test("The category decodes from the gateway record and the disk cache")
    internal func categoryDecodes() throws {
        let wire = LivingArtifact.from([
            "id": AnyCodable("trip"), "kind": AnyCodable("markdown"), "category": AnyCodable("Travel"),
        ])
        #expect(wire?.category == "Travel")
        #expect(LivingArtifact.from(["id": AnyCodable("trip")])?.category.isEmpty == true)

        let cached = try JSONDecoder().decode(
            LivingArtifact.self, from: JSONEncoder().encode(artifact("trip", category: "Travel")))
        #expect(cached.category == "Travel")
        #expect(artifact("trip", category: "Travel") != artifact("trip"))
    }

    // MARK: - Store

    @Test("Filing applies locally at once and is sent to the gateway")
    internal func setCategorySends() async {
        let (store, gateway) = makeStore([artifact("trip")])
        store.setCategory(id: "trip", category: "  Travel ")
        #expect(store.artifacts["trip"]?.category == "Travel")

        await settle { gateway.categorizeCalls.count == 1 }
        #expect(gateway.categorizeCalls.first?.id == "trip")
        #expect(gateway.categorizeCalls.first?.category == "Travel")
        #expect(store.artifacts["trip"]?.rev == 3)
        #expect(store.artifacts["trip"]?.content == "# trip")
    }

    @Test("The gateway's spelling of an existing folder is adopted")
    internal func setCategoryAdoptsSpelling() async {
        let (store, gateway) = makeStore([artifact("trip")])
        gateway.storedSpelling = "Travel"
        store.setCategory(id: "trip", category: "travel")
        await settle { store.artifacts["trip"]?.category == "Travel" }
        #expect(store.artifacts["trip"]?.category == "Travel")
    }

    @Test("A refused move puts the artifact back in its folder")
    internal func setCategoryReverts() async {
        let (store, gateway) = makeStore([artifact("trip", category: "Travel")])
        gateway.categorizeError = Refused()
        store.setCategory(id: "trip", category: "Work")
        #expect(store.artifacts["trip"]?.category == "Work")
        await settle { store.artifacts["trip"]?.category == "Travel" }
        #expect(store.artifacts["trip"]?.category == "Travel")
    }

    @Test("A pull adopts a folder changed elsewhere though rev did not move")
    internal func pullAdoptsCategory() async {
        let (store, gateway) = makeStore([artifact("trip"), artifact("notes", category: "Work")])
        gateway.listed = [artifact("trip", category: "Travel"), artifact("notes")]
        await store.pull()
        #expect(store.artifacts["trip"]?.category == "Travel")
        #expect(store.artifacts["notes"]?.category.isEmpty == true)
        #expect(store.artifacts["trip"]?.content == "# trip")
    }

    @Test("An artifact.changed for a filing adopts the folder at the same rev")
    internal func eventAdoptsCategory() async {
        let (store, gateway) = makeStore([artifact("trip")])
        gateway.fetched = artifact("trip", category: "Travel")
        store.applyGatewayEventForTesting(.artifactChanged(id: "trip", deleted: false))
        await settle { store.artifacts["trip"]?.category == "Travel" }
        #expect(store.artifacts["trip"]?.category == "Travel")
    }

    @Test("A local re-emit keeps the artifact in its folder")
    internal func upsertKeepsCategory() {
        let (store, _) = makeStore([artifact("trip", category: "Travel")])
        store.upsert(id: "trip", kind: "markdown", title: nil, content: "# trip v2")
        #expect(store.artifacts["trip"]?.category == "Travel")
    }

    // MARK: - Capability

    @Test("Filing is offered only by a gateway that advertises it")
    internal func capabilityGate() {
        func capabilities(_ names: Set<String>) -> GatewayCapabilities {
            GatewayCapabilities(
                gatewayVersion: nil, agentVersion: nil, capabilityNames: names,
                hasImageInput: false, hasACPImagePrompts: false,
                source: .gateway(method: "gateway.capabilities"))
        }
        #expect(!capabilities(["artifact.set", "artifact.list"]).supportsArtifactCategories)
        #expect(capabilities(["artifact.set", "artifact.categorize"]).supportsArtifactCategories)
    }
}
