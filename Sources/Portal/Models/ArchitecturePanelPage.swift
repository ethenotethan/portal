import Foundation

// MARK: - The observatory renderer as an in-app page

/// Builds the self-contained HTML page that presents an architecture model
/// natively: the Architecture Observatory's own `index.html`, `styles.css` and
/// `app.js` (embedded by the architecture compiler as
/// `ArchitectureObservatoryAssets`, so the two never drift) with the model the
/// gateway returned spliced in where the site loads `data.js`.
///
/// Pure string work, so the assembly is unit-testable with tiny stand-in
/// assets; the convenience overload uses the real ones.
internal enum ArchitecturePanelPage {
    internal static let stylesheetTag = "<link rel=\"stylesheet\" href=\"styles.css\">"
    internal static let dataScriptTag = "<script src=\"data.js\"></script>"
    internal static let historyScriptTag = "<script src=\"history.js\"></script>"
    internal static let appScriptTag = "<script src=\"app.js\"></script>"

    internal static func html(modelJSON: String) -> String {
        html(
            modelJSON: modelJSON,
            index: ArchitectureObservatoryAssets.indexHTML,
            appJS: ArchitectureObservatoryAssets.appJS,
            stylesCSS: ArchitectureObservatoryAssets.stylesCSS
        )
    }

    internal static func html(modelJSON: String, index: String, appJS: String, stylesCSS: String) -> String {
        var page = index
        page = page.replacingOccurrences(of: stylesheetTag, with: "<style>\n\(stylesCSS)\n</style>")
        page = page.replacingOccurrences(
            of: dataScriptTag,
            with: "<script>window.PORTAL_ARCHITECTURE={\"model\":\(scriptSafe(modelJSON))};</script>"
        )
        // The history slider is an opt-in artifact of the site build; the gateway
        // serves revisions through architecture.history instead.
        page = page.replacingOccurrences(of: historyScriptTag, with: "")
        page = page.replacingOccurrences(of: appScriptTag, with: "<script>\n\(appJS)\n</script>")
        return page
    }

    /// JSON is not HTML-safe inside `<script>`: a `</` sequence (as in a string
    /// holding `</script>`) would end the element early. Escaping the slash is
    /// valid JSON and inert to the HTML parser.
    internal static func scriptSafe(_ json: String) -> String {
        json.replacingOccurrences(of: "</", with: "<\\/")
    }

    /// The page's base URL, so the observatory's relative links (repository,
    /// source lines) resolve to the service's GitHub repository and open
    /// externally. `nil` for a service with no repository: those links stay inert.
    internal static func baseURL(repository: String?) -> URL? {
        guard let repository, !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/")
    }
}
