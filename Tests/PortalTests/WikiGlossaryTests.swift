import Foundation
import Testing
@testable import Portal

@Suite("Wiki glossary wire contract")
internal struct WikiGlossaryWireTests {
    @Test("decodes the normalized glossary response")
    internal func decodesResponse() throws {
        let data = Data(#"""
        {
          "enabled": true,
          "version": 1,
          "mode": "strict",
          "proper_nouns": [
            {"canonical": "Hermes Agent", "aliases": ["Hermes", "HA"], "description": "Agent runtime"},
            {"canonical": "Portal", "aliases": []}
          ],
          "revision": "sha256:abc123"
        }
        """#.utf8)

        let glossary = try JSONDecoder().decode(WikiGlossary.self, from: data)

        #expect(glossary.enabled)
        #expect(glossary.version == 1)
        #expect(glossary.mode == .strict)
        #expect(glossary.properNouns.count == 2)
        #expect(glossary.properNouns[0].canonical == "Hermes Agent")
        #expect(glossary.properNouns[0].aliases == ["Hermes", "HA"])
        #expect(glossary.properNouns[0].description == "Agent runtime")
        #expect(glossary.properNouns[1].description == nil)
        #expect(glossary.revision == "sha256:abc123")
    }

    @MainActor
    @Test("update payload preserves the selected wiki and optimistic revision")
    internal func updatePayload() throws {
        let terms = [
            WikiGlossary.ProperNoun(
                canonical: "Hermes Agent",
                aliases: ["Hermes", "HA"],
                description: "Agent runtime"
            ),
        ]

        let params = GatewayClient.wikiGlossaryUpdateParams(
            wiki: "research",
            version: 1,
            mode: .strict,
            properNouns: terms,
            ifMatch: "sha256:old"
        )

        #expect(params["wiki"] == AnyCodable("research"))
        #expect(params["version"] == AnyCodable(1))
        #expect(params["mode"] == AnyCodable("strict"))
        #expect(params["if_match"] == AnyCodable("sha256:old"))
        let encodedTerms = try #require(params["proper_nouns"]?.arrayValue)
        let term = try #require(encodedTerms.first?.dictionaryValue)
        #expect(term["canonical"] == AnyCodable("Hermes Agent"))
        #expect(term["aliases"] == .array([AnyCodable("Hermes"), AnyCodable("HA")]))
        #expect(term["description"] == AnyCodable("Agent runtime"))
    }
}

@MainActor
@Suite("Wiki glossary editor state")
internal struct WikiGlossaryEditorStateTests {
    @Test("validation rejects blank and duplicate canonical names")
    internal func validatesCanonicalNames() {
        let model = WikiGlossaryEditorModel(wiki: "research")
        model.terms = [
            .init(canonical: " Hermes Agent ", aliases: "Hermes, HA", description: ""),
            .init(canonical: "hermes agent", aliases: "", description: "Duplicate"),
            .init(canonical: "   ", aliases: "", description: ""),
        ]

        #expect(!model.isValid)
        #expect(model.validationMessage?.contains("unique") == true)
        #expect(model.validationMessage?.contains("canonical") == true)
    }

    @Test("load seeds editable state for the originally selected wiki")
    internal func loadSeedsState() async {
        let source = GlossarySourceStub(
            glossary: WikiGlossary(
                enabled: true,
                version: 1,
                mode: .strict,
                properNouns: [
                    .init(
                        canonical: "Portal",
                        aliases: ["Hermes Native", "Portal, desktop"],
                        description: "Desktop client"
                    ),
                ],
                revision: "rev-1"
            )
        )
        let model = WikiGlossaryEditorModel(wiki: "research")

        await model.load(using: source)

        #expect(source.loadedWiki == "research")
        #expect(model.version == 1)
        #expect(model.mode == .strict)
        #expect(model.revision == "rev-1")
        #expect(model.terms.first?.aliases == "Hermes Native\nPortal, desktop")
        #expect(model.status == .idle)
    }

    @Test("save normalizes fields and preserves the selected wiki revision")
    internal func saveNormalizesMutation() async {
        let source = GlossarySourceStub(glossary: .fixture(revision: "rev-old"))
        let model = WikiGlossaryEditorModel(wiki: "life")
        await model.load(using: source)
        model.mode = .strict
        model.terms = [
            .init(canonical: " Ethen ", aliases: " Ethan\n E ", description: " Owner "),
        ]

        let saved = await model.save(using: source)

        #expect(saved)
        #expect(source.updatedWiki == "life")
        #expect(source.updatedVersion == 1)
        #expect(source.updatedMode == .strict)
        #expect(source.updatedIfMatch == "rev-old")
        #expect(source.updatedTerms == [
            .init(canonical: "Ethen", aliases: ["Ethan", "E"], description: "Owner"),
        ])
    }

    @Test("save surfaces optimistic concurrency conflicts")
    internal func saveSurfacesConflict() async {
        let source = GlossarySourceStub(
            glossary: .fixture(revision: "rev-old"),
            updateError: WikiGlossaryConflict()
        )
        let model = WikiGlossaryEditorModel(wiki: "research")
        await model.load(using: source)

        #expect(!(await model.save(using: source)))
        #expect(model.status == .conflict)
        #expect(!model.canSave)
    }

    @Test("a failed initial load cannot save an uninitialized policy")
    internal func failedLoadDisablesSave() async {
        let source = GlossarySourceStub(
            glossary: .fixture(revision: "rev-old"),
            loadError: StubError.failed
        )
        let model = WikiGlossaryEditorModel(wiki: "research")

        await model.load(using: source)

        #expect(model.errorMessage != nil)
        #expect(!model.canSave)
    }

    private enum StubError: Error { case failed }
}

private extension WikiGlossary {
    static func fixture(revision: String) -> WikiGlossary {
        WikiGlossary(
            enabled: true,
            version: 1,
            mode: .canonicalize,
            properNouns: [],
            revision: revision
        )
    }
}

@MainActor
private final class GlossarySourceStub: WikiGlossarySource {
    let glossary: WikiGlossary
    let loadError: Error?
    let updateError: Error?
    var loadedWiki: String?
    var updatedWiki: String?
    var updatedVersion: Int?
    var updatedMode: WikiGlossary.Mode?
    var updatedTerms: [WikiGlossary.ProperNoun]?
    var updatedIfMatch: String?

    init(glossary: WikiGlossary, loadError: Error? = nil, updateError: Error? = nil) {
        self.glossary = glossary
        self.loadError = loadError
        self.updateError = updateError
    }

    func wikiGlossary(wiki: String?) async throws -> WikiGlossary {
        loadedWiki = wiki
        if let loadError { throw loadError }
        return glossary
    }

    func wikiGlossaryUpdate(
        wiki: String?,
        version: Int,
        mode: WikiGlossary.Mode,
        properNouns: [WikiGlossary.ProperNoun],
        ifMatch: String?
    ) async throws -> WikiGlossary {
        updatedWiki = wiki
        updatedVersion = version
        updatedMode = mode
        updatedTerms = properNouns
        updatedIfMatch = ifMatch
        if let updateError { throw updateError }
        return glossary
    }
}
