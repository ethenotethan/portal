import Testing
import Foundation
@testable import Portal

@Suite("Architecture inventory — the components, invariants, stores and externals sections decoded natively")
internal struct ArchitectureInventoryDocumentTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PortalTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    private func realModel() throws -> AnyCodable {
        let url = Self.repoRoot.appendingPathComponent("architecture/model/model.json")
        return try JSONDecoder().decode(AnyCodable.self, from: Data(contentsOf: url))
    }

    private let fixture = """
    {
      "schema_version": "1.0.0",
      "layers": [{"id": "foundation", "label": "Foundation", "order": 3}, {"id": "experience", "label": "Experience", "order": 0}],
      "components": [
        {"id": "chat-ui", "label": "Chat UI", "layer": "experience", "description": "The conversation.", "external": false,
         "file_count": 2, "line_count": 300, "declaration_count": 3, "files": ["Sources/Portal/Views/ChatView.swift", "Sources/Portal/Views/Bubble.swift"],
         "declarations": ["ChatView", "Bubble", "BubbleRow"]},
        {"id": "domain-models", "label": "Domain models", "layer": "foundation", "description": "Types.", "external": false,
         "file_count": 1, "line_count": 50, "declaration_count": 1, "files": ["Sources/Portal/Models/Item.swift"], "declarations": ["Item"]},
        {"id": "hermes-gateway", "label": "Gateway", "layer": "external", "description": "Outside.", "external": true,
         "file_count": 0, "line_count": 0, "declaration_count": 0, "files": [], "declarations": []},
        {"label": "no id, skipped"}
      ],
      "interplay": {"nodes": [], "edges": [], "flows": [],
        "invariants": [
          {"id": "single-transport", "kind": "single_transport", "status": "holds", "why": "One socket.", "checked": 1},
          {"id": "pool-guarded", "kind": "pool_guarded_by_lock", "status": "violated", "why": "Lock it.", "checked": 4},
          {"kind": "no id"}
        ]},
      "stores": {"items": [
        {"id": "store-1", "label": "ActivityStore", "kind": "class", "component": "domain-models", "persistence": ["defaults", "file"],
         "mechanisms": [{"kind": "defaults", "label": "UserDefaults"}, {"kind": "file", "label": ".applicationSupportDirectory"}],
         "artifacts": [{"kind": "defaults_key", "label": "portal.activityItems"}, {"kind": "file", "label": "activity.json"}, {"kind": "x"}],
         "evidence": {"path": "Sources/Portal/Models/ActivityStore.swift", "line": 7}},
        {"id": "store-2", "type_name": "MemoryCache", "kind": "struct", "persistence": [], "mechanisms": [], "artifacts": []},
        {"id": "store-3", "label": "TokenLedger", "kind": "class", "persistence": ["keychain"], "mechanisms": [], "artifacts": [], "evidence": {"line": 3}}
      ]},
      "externals": {"systems": [
        {"id": "harness-gateway", "label": "Harness gateway", "category": "backend", "description": "RPC.", "component": "hermes-gateway",
         "protocol": "WebSocket JSON-RPC", "hit_count": 15, "file_count": 5},
        {"id": "user-defaults", "label": "UserDefaults", "category": "storage", "description": "Prefs.", "hit_count": 108, "file_count": 32},
        {"id": "apple-mlx", "label": "Apple MLX", "category": "", "description": "", "hit_count": 3, "file_count": 3}
      ]}
    }
    """

    @Test("decodes every section tolerantly, skipping records without an id")
    internal func decodesFixture() throws {
        let inventory = ArchitectureInventoryDocument.decode(model: try decode(fixture))
        #expect(inventory.layers.map(\.id) == ["experience", "foundation"], "layers come back in order")
        #expect(inventory.components.map(\.id) == ["chat-ui", "domain-models", "hermes-gateway"])
        let chat = try #require(inventory.components.first)
        #expect(chat.label == "Chat UI")
        #expect(chat.layer == "experience")
        #expect(chat.fileCount == 2)
        #expect(chat.lineCount == 300)
        #expect(chat.declarationCount == 3)
        #expect(chat.files.count == 2)
        #expect(chat.declarations == ["ChatView", "Bubble", "BubbleRow"])
        #expect(!chat.external)
        #expect(inventory.components.last?.external == true)
        #expect(inventory.invariants.map(\.id) == ["single-transport", "pool-guarded"])
        #expect(inventory.invariants[0].holds)
        #expect(!inventory.invariants[1].holds)
        #expect(inventory.invariants[1].checked == 4)
        #expect(inventory.hasStoresSection)
        #expect(inventory.hasExternalsSection)
        let activity = try #require(inventory.stores.first)
        #expect(activity.label == "ActivityStore")
        #expect(activity.primaryPersistence == "defaults")
        #expect(activity.mechanisms == ["UserDefaults", ".applicationSupportDirectory"])
        #expect(activity.artifacts.map(\.label) == ["portal.activityItems", "activity.json"], "an artifact without a label is skipped")
        #expect(activity.evidence?.location == "Sources/Portal/Models/ActivityStore.swift:7")
        let cache = inventory.stores[1]
        #expect(cache.label == "MemoryCache", "type_name is the fallback label")
        #expect(cache.primaryPersistence == "unobserved")
        #expect(cache.evidence == nil)
        #expect(inventory.stores[2].evidence == nil, "evidence without a path is no evidence")
        let gateway = try #require(inventory.externals.first)
        #expect(gateway.protocolName == "WebSocket JSON-RPC")
        #expect(gateway.hitCount == 15)
        #expect(gateway.component == "hermes-gateway")
        #expect(inventory.externals[1].component == nil)
        #expect(inventory.layerLabel("foundation") == "Foundation")
        #expect(inventory.layerLabel("external") == "external")
        #expect(inventory.layerLabel("") == "Unlayered")
    }

    @Test("a document without the optional sections decodes as empty, not as an error")
    internal func optionalSectionsAbsent() throws {
        let inventory = ArchitectureInventoryDocument.decode(model: try decode("{\"schema_version\": \"1.0.0\", \"components\": []}"))
        #expect(inventory.components.isEmpty)
        #expect(inventory.invariants.isEmpty)
        #expect(!inventory.hasStoresSection)
        #expect(!inventory.hasExternalsSection)
        #expect(inventory.stores.isEmpty)
        #expect(ArchitectureInventoryDocument.decode(model: .string("not a model")) == .empty)
        #expect(ArchitectureInventoryDocument.decode(model: .array([])) == .empty)
    }

    @Test("decodes through the gateway document envelope")
    internal func decodesFromDocument() throws {
        let envelope = """
        {"service": {"id": "arch:x", "label": "X", "description": "", "source": "local", "model_path": "m", "check_configured": false},
         "revision": "r", "model": \(fixture)}
        """
        let document = try ArchitectureModelDocument.decodeGatewayValue(try decode(envelope))
        let inventory = ArchitectureInventoryDocument.decode(document)
        #expect(inventory.components.count == 3)
        #expect(inventory.stores.count == 3)
        #expect(document.sections.contains(.stores))
    }

    @Test("the committed Portal model decodes: every component has files, every layer is known, invariants hold")
    internal func decodesTheRealModel() throws {
        let inventory = ArchitectureInventoryDocument.decode(model: try realModel())
        #expect(inventory.components.count >= 15)
        #expect(inventory.layers.count == 5)
        let layerIDs = Set(inventory.layers.map(\.id))
        for component in inventory.components where !component.external {
            let counted = component.fileCount == component.files.count
            let layered = layerIDs.contains(component.layer)
            #expect(counted, "\(component.id) counts its files")
            #expect(layered, "\(component.id) sits in an undeclared layer \(component.layer)")
        }
        #expect(inventory.invariants.count >= 10)
        let allHold = inventory.invariants.allSatisfy(\.holds)
        #expect(allHold, "the compiler fails the build on a violated invariant")
        #expect(inventory.stores.count >= 15)
        let storesCited = inventory.stores.allSatisfy { $0.evidence != nil }
        #expect(storesCited)
        #expect(inventory.externals.count >= 10)
        let categorised = inventory.externals.allSatisfy { !$0.category.isEmpty }
        #expect(categorised)
    }
}

@Suite("Architecture inventory model — grouping, sorting and search")
internal struct ArchitectureInventoryModelTests {
    private func inventory() throws -> ArchitectureInventoryDocument {
        let fixture = try JSONDecoder().decode(AnyCodable.self, from: Data(ArchitectureInventoryDocumentTests().fixtureJSON.utf8))
        return ArchitectureInventoryDocument.decode(model: fixture)
    }

    @Test("components group by layer in model order, external components excluded, labels sorted")
    internal func layerGroups() throws {
        let model = ArchitectureInventoryModel(inventory: try inventory())
        #expect(model.layerGroups.map(\.id) == ["experience", "foundation"])
        #expect(model.layerGroups[0].label == "Experience")
        #expect(model.layerGroups[0].components.map(\.id) == ["chat-ui"])
        #expect(model.layerGroups[0].fileCount == 2)
        #expect(model.layerGroups[0].lineCount == 300)
        #expect(model.componentCount == 2, "the external gateway component is not inventory")
        #expect(model.totalFiles == 3)
        #expect(model.totalLines == 350)
        #expect(model.invariantsHolding == 1)
    }

    @Test("search narrows components (by file and declaration too), invariants, stores and externals")
    internal func search() throws {
        var model = ArchitectureInventoryModel(inventory: try inventory(), query: "  BubbleRow ")
        #expect(model.layerGroups.flatMap(\.components).map(\.id) == ["chat-ui"], "a declaration name finds its component")
        #expect(model.invariants.isEmpty)
        #expect(model.storeGroups.isEmpty)
        #expect(model.externalGroups.isEmpty)
        model.query = "lock"
        #expect(model.invariants.map(\.id) == ["pool-guarded"])
        model.query = "activity.json"
        #expect(model.storeGroups.flatMap(\.items).map(\.id) == ["store-1"], "an artifact name finds its store")
        model.query = "json-rpc"
        #expect(model.externalGroups.flatMap(\.items).map(\.id) == ["harness-gateway"], "a protocol finds its external")
        model.query = "Views/"
        #expect(model.layerGroups.flatMap(\.components).map(\.id) == ["chat-ui"], "a file path finds its component")
        model.query = ""
        #expect(model.layerGroups.flatMap(\.components).count == 2)
    }

    @Test("selection exposes the component's files and declarations, narrowed only when the search hits them")
    internal func selection() throws {
        var model = ArchitectureInventoryModel(inventory: try inventory(), selectedComponentID: "chat-ui")
        #expect(model.selectedComponent?.label == "Chat UI")
        #expect(model.selectedFiles.count == 2)
        #expect(model.selectedDeclarations.count == 3)
        model.query = "bubble"
        #expect(model.selectedFiles == ["Sources/Portal/Views/Bubble.swift"])
        #expect(model.selectedDeclarations == ["Bubble", "BubbleRow"])
        model.query = "zzz"
        #expect(model.selectedFiles.count == 2, "a search that hits nothing inside the component shows everything")
        #expect(model.selectedDeclarations.count == 3)
        model.selectedComponentID = "missing"
        #expect(model.selectedComponent == nil)
        #expect(model.selectedFiles.isEmpty)
        #expect(model.selectedDeclarations.isEmpty)
    }

    @Test("stores group by persistence mechanism in file, defaults, keychain, unobserved order")
    internal func storeGroups() throws {
        let model = ArchitectureInventoryModel(inventory: try inventory())
        #expect(model.storeGroups.map(\.id) == ["defaults", "keychain", "unobserved"])
        #expect(model.storeGroups.map(\.label) == ["UserDefaults", "Keychain", "In memory or delegated (unobserved)"])
        #expect(model.storeGroups[0].items.map(\.label) == ["ActivityStore"])
        #expect(ArchitectureInventoryModel.persistenceLabel("file") == "File system")
        #expect(ArchitectureInventoryModel.persistenceLabel("sqlite") == "sqlite")
    }

    @Test("externals group by category alphabetically, an empty category labelled as such")
    internal func externalGroups() throws {
        let model = ArchitectureInventoryModel(inventory: try inventory())
        #expect(model.externalGroups.map(\.id) == ["", "backend", "storage"])
        #expect(model.externalGroups.map(\.label) == ["Uncategorised", "Backend", "Storage"])
        #expect(model.externalGroups[1].items.map(\.id) == ["harness-gateway"])
    }
}

extension ArchitectureInventoryDocumentTests {
    /// The fixture, shared with the model tests.
    internal var fixtureJSON: String { fixture }
}
