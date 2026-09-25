import Testing
@testable import Portal

@Suite("Blueprint Spec")
internal struct BlueprintSpecTests {
    @Test("blueprint fences route to the native renderer")
    internal func fenceRouting() {
        #expect(MarkdownParser.isBlueprintLanguage("blueprint"))
        #expect(MarkdownParser.isBlueprintLanguage(" Blueprint "))
        #expect(!MarkdownParser.isBlueprintLanguage("architecture"))
        #expect(!MarkdownParser.isDiagramLanguage("blueprint"))
    }

    @Test("parses placed elements and connections with safe defaults")
    internal func parsesSpec() throws {
        let spec = try #require(BlueprintSpec.parse("""
        {"title":"Inference rig","width":120,"height":80,"grid":false,
         "elements":[
           {"id":"edge","label":"Edge","x":5,"y":8,"width":35,"height":28,"kind":"boundary"},
           {"id":"api","label":"API","x":12,"y":16,"width":16,"height":8,"kind":"service","note":"public"},
           {"id":"db","label":"Postgres","x":74,"y":52,"width":18,"height":12,"kind":"storage"}],
         "connections":[{"from":"api","to":"db","label":"SQL","style":"data","arrow":true}]}
        """))

        #expect(spec.title == "Inference rig")
        #expect(spec.canvasWidth == 120)
        #expect(spec.canvasHeight == 80)
        #expect(!spec.showsGrid)
        #expect(spec.elements.count == 3)
        #expect(spec.elements[1].kind == .service)
        #expect(spec.elements[1].note == "public")
        #expect(spec.connections.count == 1)
        #expect(spec.connections[0].style == .data)
        #expect(spec.connections[0].hasArrow)
    }

    @Test("sanitizes duplicate elements, bounds geometry, and drops dangling links")
    internal func sanitizesSpec() throws {
        let spec = try #require(BlueprintSpec.parse("""
        {"elements":[
          {"id":"a","x":-10,"y":130,"width":0,"height":900},
          {"id":"a","x":20,"y":20,"width":20,"height":20},
          {"id":"b","x":80,"y":40,"width":10,"height":10}],
         "connections":[{"from":"a","to":"b"},{"from":"a","to":"ghost"}]}
        """))

        #expect(spec.elements.count == 2)
        #expect(spec.elements[0].x == 0)
        #expect(spec.elements[0].y == 99)
        #expect(spec.elements[0].width == 1)
        #expect(spec.elements[0].height == 100)
        #expect(spec.connections.count == 1)
        #expect(spec.showsGrid)
    }

    @Test("rejects malformed or empty blueprints")
    internal func rejectsInvalidSpecs() {
        #expect(BlueprintSpec.parse("not json") == nil)
        #expect(BlueprintSpec.parse(#"{"elements":[]}"#) == nil)
    }

    @Test("canvas sizing preserves the declared blueprint aspect ratio")
    internal func preservesAspectRatio() {
        #expect(BlueprintCanvasSizing.height(width: 600, canvasWidth: 120, canvasHeight: 80) == 400)
        #expect(BlueprintCanvasSizing.height(width: 300, canvasWidth: 100, canvasHeight: 100) == 300)
    }
}
