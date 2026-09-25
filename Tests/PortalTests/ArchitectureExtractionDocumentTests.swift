import Testing
import Foundation
@testable import Portal

@Suite("Architecture extraction document — the `extraction` section of the contract")
internal struct ArchitectureExtractionDocumentTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func decode(_ json: String) throws -> AnyCodable {
        try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
    }

    /// The real compiled model: the contract requires every construction on the
    /// map to have provenance, so this is the strongest fixture there is.
    internal static func realModel() throws -> AnyCodable {
        let url = repoRoot.appendingPathComponent("architecture/model/model.json")
        return try JSONDecoder().decode(AnyCodable.self, from: Data(contentsOf: url))
    }

    internal static let fixture = """
    {
      "authority": "observed",
      "derivation": "Every (pass, file, line) the model cites, joined by line range.",
      "families": {"store": "Store rules", "trigger": "Trigger rules"},
      "files": [
        {"path": "Sources/App/Models/ActivityStore.swift", "component": "domain-models", "line_count": 120, "citations": 3,
         "semantic_citations": 1, "touched": true, "declaration_count": 3, "mapped_declarations": 2,
         "passes": ["swift.store.declaration", "swift.store.defaults_key_literal"],
         "declarations": [
           {"kind": "class", "name": "ActivityStore", "line": 7, "passes": ["swift.store.declaration"]},
           {"kind": "func", "name": "save", "line": 20, "passes": ["swift.store.defaults_key_literal"]},
           {"kind": "func", "name": "helper", "line": 40, "passes": []}
         ]},
        {"path": "Sources/App/Models/ActivityItem.swift", "component": "domain-models", "line_count": 40, "citations": 0,
         "semantic_citations": 0, "touched": false, "declaration_count": 2, "mapped_declarations": 0, "passes": [],
         "declarations": [{"kind": "struct", "name": "ActivityItem", "line": 3, "passes": []}, {"kind": "enum", "name": "Kind", "line": 9, "passes": []}]},
        {"path": "Sources/App/Views/ChatView.swift", "component": "shared-ui", "line_count": 300, "citations": 2, "semantic_citations": 0,
         "touched": true, "declaration_count": 1, "mapped_declarations": 1, "passes": ["swift.trigger.surface_call"],
         "declarations": [{"kind": "struct", "name": "ChatView", "line": 5, "passes": ["swift.trigger.surface_call"]}]},
        {"path": "App/IOSApp.swift", "component": null, "line_count": 30, "citations": 1, "semantic_citations": 0, "touched": true,
         "declaration_count": 1, "mapped_declarations": 1, "passes": ["swift.trigger.launch_construction"],
         "declarations": [{"kind": "struct", "name": "PortalAppIOS", "line": 4, "passes": ["swift.trigger.launch_construction"]}]}
      ],
      "passes": [
        {"id": "swift.store.declaration", "class": "mechanical", "description": "A type named like a store", "files": 1, "citations": 1},
        {"id": "swift.store.defaults_key_literal", "class": "mechanical", "description": "A defaults key", "files": 1, "citations": 2},
        {"id": "swift.trigger.surface_call", "class": "mechanical", "description": "A SwiftUI action", "files": 1, "citations": 2},
        {"id": "swift.trigger.launch_construction", "class": "mechanical", "description": "A launch construction", "files": 1, "citations": 1},
        {"id": "semantic.flow", "class": "semantic", "description": "A flow written by a person", "files": 1, "citations": 1}
      ],
      "entities": [
        {"id": "store:domain-models:ActivityStore", "kind": "store", "label": "ActivityStore", "component": "domain-models", "origins": [
          {"path": "Sources/App/Models/ActivityStore.swift", "line": 7, "rule": "swift.store.declaration", "family": "store"},
          {"path": "Sources/App/Models/ActivityStore.swift", "line": 20, "rule": "swift.store.defaults_key_literal", "family": "store"}
        ]},
        {"id": "artifact:user-defaults:portal.activityItems", "kind": "artifact", "label": "portal.activityItems", "component": "device-services",
         "origins": [{"path": "Sources/App/Models/ActivityStore.swift", "line": 20, "rule": "swift.store.defaults_key_literal", "family": "store"}]},
        {"id": "caller:chat-state:ChatViewModel", "kind": "caller", "label": "ChatViewModel", "component": "chat-state", "origins": [
          {"path": "Sources/App/Views/ChatView.swift", "line": 188, "rule": "swift.trigger.surface_call", "family": "trigger", "via": "trigger"},
          {"path": "Sources/App/Views/ChatView.swift", "line": 240, "rule": "swift.trigger.surface_call", "family": "trigger", "via": "trigger"}
        ]},
        {"id": "provider:operations-state:SettingsViewModel", "kind": "provider", "label": "SettingsViewModel", "component": "operations-state",
         "origins": [{"path": "App/IOSApp.swift", "line": 7, "rule": "swift.trigger.launch_construction", "family": "trigger"}]},
        {"id": "custom:thing", "kind": "widget", "label": "Widget", "component": null,
         "origins": [{"path": "Sources/App/Views/ChatView.swift", "line": 9, "rule": "map.widget", "family": "novel"}]}
      ],
      "summary": {
        "files": 4, "touched_files": 3, "untouched_files": 1, "declarations": 7, "mapped_declarations": 4,
        "entities": 5, "entities_with_origin": 5, "passes": 4, "citations": 6, "semantic_citations": 1,
        "by_kind": {"class": {"total": 1, "mapped": 1}, "func": {"total": 2, "mapped": 1}, "struct": {"total": 3, "mapped": 2}, "enum": {"total": 1, "mapped": 0}},
        "types": {"total": 5, "mapped": 3}, "functions": {"total": 2, "mapped": 1}
      }
    }
    """

    internal static func fixtureDocument() throws -> ArchitectureExtractionDocument {
        let value = try JSONDecoder().decode(AnyCodable.self, from: Data(fixture.utf8))
        return try #require(ArchitectureExtractionDocument.decode(value.dictionaryValue))
    }

    @Test("decodes files, declarations, passes, entities, origins and the summary")
    internal func decodesFixture() throws {
        let document = try Self.fixtureDocument()
        #expect(document.authority == "observed")
        #expect(document.derivation.hasPrefix("Every (pass, file, line)"))
        #expect(document.families["store"] == "Store rules")
        #expect(document.files.count == 4)
        let store = try #require(document.fileByPath["Sources/App/Models/ActivityStore.swift"])
        #expect(store.component == "domain-models")
        #expect(store.fileName == "ActivityStore.swift")
        #expect(store.directory == "Sources/App/Models")
        #expect(store.lineCount == 120)
        #expect(store.touched)
        #expect(store.semanticCitations == 1)
        #expect(store.declarations.map(\.name) == ["ActivityStore", "save", "helper"])
        #expect(store.declarations.filter(\.isMapped).count == 2)
        #expect(store.mappedShare == 2.0 / 3.0)
        let item = try #require(document.fileByPath["Sources/App/Models/ActivityItem.swift"])
        #expect(!item.touched)
        #expect(item.mappedShare == 0)
        #expect(document.passes.count == 5)
        #expect(document.passes.filter(\.isMechanical).count == 4)
        let semantic = try #require(document.passes.first { $0.id == "semantic.flow" })
        #expect(semantic.passClass == .semantic)
        #expect(!semantic.isMechanical)
        #expect(document.entities.count == 5)
        let caller = try #require(document.entityByID["caller:chat-state:ChatViewModel"])
        #expect(caller.kind == "caller")
        #expect(caller.origins.count == 2)
        #expect(caller.origins[0].family == .trigger)
        #expect(caller.origins[0].via == "trigger")
        #expect(caller.origins[0].line == 188)
        let novel = try #require(document.entityByID["custom:thing"])
        #expect(novel.origins[0].family == .custom("novel"))
        #expect(novel.origins[0].family.rawValue == "novel")
        #expect(novel.origins[0].family.label == "novel")
        #expect(novel.component == nil)
        #expect(document.summary.files == 4)
        #expect(document.summary.touchedFiles == 3)
        #expect(document.summary.untouchedFiles == 1)
        #expect(document.summary.entitiesWithOrigin == 5)
        #expect(document.summary.types == ArchitectureExtractionCount(total: 5, mapped: 3))
        #expect(document.summary.functions.unmapped == 1)
        #expect(document.summary.byKind["enum"]?.share == 0)
        #expect(document.summary.byKind["class"]?.share == 1)
        #expect(document.summary.citations == 6)
        #expect(document.summary.semanticCitations == 1)
    }

    @Test("families and pass classes are open: known values map, unknown ones are kept")
    internal func openEnums() {
        #expect(ArchitectureExtractionFamily(rawValue: "store") == .store)
        #expect(ArchitectureExtractionFamily(rawValue: "behaviour") == .behaviour)
        #expect(ArchitectureExtractionFamily(rawValue: "boundary") == .boundary)
        #expect(ArchitectureExtractionFamily(rawValue: "wiring") == .wiring)
        #expect(ArchitectureExtractionFamily(rawValue: "trigger") == .trigger)
        for family in ArchitectureExtractionFamily.known {
            #expect(ArchitectureExtractionFamily(rawValue: family.rawValue) == family)
            #expect(!family.label.isEmpty)
        }
        #expect(ArchitectureExtractionFamily.behaviour.label == "behaviour rules")
        #expect(ArchitectureExtractionFamily.boundary.label == "boundary signatures")
        #expect(ArchitectureExtractionFamily.wiring.label == "map wiring")
        #expect(ArchitectureExtractionPassClass(rawValue: "mechanical") == .mechanical)
        #expect(ArchitectureExtractionPassClass(rawValue: "semantic").rawValue == "semantic")
        #expect(ArchitectureExtractionPassClass(rawValue: "guessed") == .custom("guessed"))
        #expect(ArchitectureExtractionPassClass.custom("guessed").rawValue == "guessed")
        #expect(ArchitectureExtractionPassClass.mechanical.rawValue == "mechanical")
    }

    @Test("tolerates a sparse section and rejects an absent one")
    internal func tolerantDecoding() throws {
        #expect(ArchitectureExtractionDocument.decode(nil) == nil)
        let sparse = try decode("""
        {"files": [{"path": "A.swift", "citations": 2, "declarations": [{"kind": "struct", "name": "A", "line": 1, "passes": ["x"]}]}, {"nope": 1}],
         "passes": [{"id": "x"}, {"missing": true}], "entities": [{"id": "e", "origins": [{"path": "A.swift", "rule": "x"}, {"broken": 1}]}, {"label": "no id"}]}
        """)
        let document = try #require(ArchitectureExtractionDocument.decode(sparse.dictionaryValue))
        #expect(document.authority == "observed")
        #expect(document.derivation.isEmpty)
        #expect(document.families.isEmpty)
        #expect(document.files.count == 1)
        let file = document.files[0]
        #expect(file.touched, "touched defaults to citations > 0")
        #expect(file.declarationCount == 1, "counts default to the declarations decoded")
        #expect(file.mappedDeclarations == 1)
        #expect(file.lineCount == 0)
        #expect(file.directory.isEmpty)
        #expect(file.fileName == "A.swift")
        #expect(document.passes.count == 1)
        #expect(document.passes[0].isMechanical, "class defaults to mechanical")
        #expect(document.passes[0].description.isEmpty)
        #expect(document.entities.count == 1)
        #expect(document.entities[0].kind == "node")
        #expect(document.entities[0].label == "e")
        #expect(document.entities[0].origins.count == 1)
        #expect(document.entities[0].origins[0].family == .wiring, "family defaults to wiring")
        #expect(document.entities[0].origins[0].via == nil)
        #expect(document.summary == .empty)
        #expect(ArchitectureExtractionCount.decode(nil) == .zero)
        #expect(ArchitectureExtractionSummary.decode(nil) == .empty)
        let empty = ArchitectureExtractedFile(
            path: "Z.swift", component: nil, lineCount: 1, citations: 0, semanticCitations: 0, touched: true,
            declarationCount: 0, mappedDeclarations: 0, passes: [], declarations: []
        )
        #expect(empty.mappedShare == 1, "a touched file without declarations counts as fully mapped")
    }

    @Test("decodes the real compiled model and its provenance is complete")
    internal func decodesRealModel() throws {
        let model = try Self.realModel()
        let base = try #require(model.dictionaryValue)
        let document = try #require(ArchitectureExtractionDocument.decode(base["extraction"]?.dictionaryValue))
        #expect(document.files.count == document.summary.files)
        #expect(document.files.filter(\.touched).count == document.summary.touchedFiles)
        #expect(document.files.filter { !$0.touched }.count == document.summary.untouchedFiles)
        #expect(document.entities.count == document.summary.entities)
        #expect(document.entities.allSatisfy { !$0.origins.isEmpty }, "every construction has provenance")
        #expect(document.passes.filter(\.isMechanical).count == document.summary.passes)
        let passIDs = Set(document.passes.map(\.id))
        let paths = Set(document.files.map(\.path))
        for entity in document.entities {
            for origin in entity.origins {
                #expect(paths.contains(origin.path), "\(entity.id) cites \(origin.path)")
                #expect(passIDs.contains(origin.rule) || origin.rule.hasPrefix("map."), "\(origin.rule)")
                #expect(ArchitectureExtractionFamily.known.contains(origin.family), "\(origin.rule) has family \(origin.family.rawValue)")
            }
        }
        for file in document.files {
            #expect(file.touched == (file.citations > 0), "\(file.path)")
            #expect(file.mappedDeclarations == file.declarations.filter(\.isMapped).count, "\(file.path)")
        }
        // The whole-document convenience goes through ArchitectureModelDocument's section lookup.
        let envelope = AnyCodable.dictionary([
            "service": .dictionary(["id": .string("arch:portal"), "label": .string("Portal")]),
            "revision": .string("r"), "model": model,
        ])
        let wrapped = try ArchitectureModelDocument.decodeGatewayValue(envelope)
        #expect(ArchitectureExtractionDocument.decode(document: wrapped)?.files.count == document.files.count)
    }
}
