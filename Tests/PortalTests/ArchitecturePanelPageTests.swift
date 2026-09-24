import Testing
import Foundation
@testable import Portal

@Suite("Architecture panel page — the observatory renderer around a model")
internal struct ArchitecturePanelPageTests {
    private let index = """
    <!doctype html><html><head><link rel="stylesheet" href="styles.css"></head>
    <body><script src="data.js"></script><script src="history.js"></script><script src="app.js"></script></body></html>
    """

    @Test("splices the stylesheet, the model and the app in place of the site's external files")
    internal func splicesAssets() throws {
        let page = ArchitecturePanelPage.html(
            modelJSON: "{\"schema_version\":\"1.0.0\"}",
            index: index,
            appJS: "console.log('app');",
            stylesCSS: "body { color: red; }"
        )
        #expect(page.contains("<style>\nbody { color: red; }\n</style>"))
        #expect(page.contains("<script>window.PORTAL_ARCHITECTURE={\"model\":{\"schema_version\":\"1.0.0\"}};</script>"))
        #expect(page.contains("<script>\nconsole.log('app');\n</script>"))
        #expect(!page.contains("src=\"data.js\""))
        #expect(!page.contains("src=\"history.js\""))
        #expect(!page.contains("src=\"app.js\""))
        #expect(!page.contains("href=\"styles.css\""))
        // The model is injected before the app runs, as the site's data.js is.
        let modelAt = try #require(page.range(of: "window.PORTAL_ARCHITECTURE"))
        let appAt = try #require(page.range(of: "console.log('app')"))
        #expect(modelAt.lowerBound < appAt.lowerBound)
    }

    @Test("a closing tag inside the model cannot end the script element")
    internal func escapesClosingTags() {
        #expect(ArchitecturePanelPage.scriptSafe("{\"p\":\"a</script><b>\"}") == "{\"p\":\"a<\\/script><b>\"}")
        let page = ArchitecturePanelPage.html(modelJSON: "{\"p\":\"</script>\"}", index: index, appJS: "", stylesCSS: "")
        #expect(!page.contains("\"</script>\""))
        #expect(page.contains("<\\/script>"))
    }

    @Test("the real renderer embeds with no external references left")
    internal func realAssetsEmbed() {
        let page = ArchitecturePanelPage.html(modelJSON: "{\"schema_version\":\"1.0.0\",\"components\":[]}")
        #expect(page.contains("window.PORTAL_ARCHITECTURE={\"model\":{\"schema_version\":\"1.0.0\",\"components\":[]}}"))
        #expect(!page.contains("src=\"data.js\""))
        #expect(!page.contains("src=\"app.js\""))
        #expect(!page.contains("src=\"history.js\""))
        #expect(!page.contains("href=\"styles.css\""))
        #expect(page.contains("id=\"gates-view\""), "the CI gates view ships with the renderer")
        #expect(page.contains("function renderInterplay()"))
        #expect(ArchitectureObservatoryAssets.indexHTML.contains(ArchitecturePanelPage.dataScriptTag))
        #expect(ArchitectureObservatoryAssets.indexHTML.contains(ArchitecturePanelPage.appScriptTag))
        #expect(ArchitectureObservatoryAssets.indexHTML.contains(ArchitecturePanelPage.stylesheetTag))
    }

    @Test("relative links resolve against the service's repository when it has one")
    internal func baseURL() {
        #expect(ArchitecturePanelPage.baseURL(repository: "ethenotethan/portal")?.absoluteString == "https://github.com/ethenotethan/portal/")
        #expect(ArchitecturePanelPage.baseURL(repository: nil) == nil)
        #expect(ArchitecturePanelPage.baseURL(repository: "") == nil)
    }
}
