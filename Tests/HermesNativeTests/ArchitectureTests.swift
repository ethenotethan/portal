import Testing
import Foundation

/// Architecture tests — enforce the layer conventions this codebase runs on
/// (Models → Services → ViewModels → Views) by reading source files directly.
///
/// These mirror the custom SwiftLint rules in `.swiftlint.yml` and exist so
/// the conventions are checked even where regex-per-file linting can't reach
/// (cross-file assertions like doc sync, or directory-structure invariants).
/// The why behind each rule lives in `docs/architecture-rules.md`.
@Suite("Architecture rules")
struct ArchitectureTests {

    // MARK: - Source tree location

    /// Repo root, located relative to this file so the tests work from
    /// `swift test`, Xcode, and CI without environment variables.
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tests/HermesNativeTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    private static let sourcesRoot = repoRoot
        .appendingPathComponent("Sources/HermesNative")

    /// All Swift files under a directory (recursive), sorted for stable output.
    private static func swiftFiles(under dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    // MARK: - Services must not import SwiftUI

    /// Allowlisted Services that import SwiftUI. ONE SOURCE OF TRUTH with the
    /// `no_swiftui_in_services` excluded list in `.swiftlint.yml` — keep the
    /// two in sync when adding or removing an exception.
    private static let swiftUIServiceAllowlist: Set<String> = [
        // Legit presentation service: renders SwiftUI views to PDF pages via
        // ImageRenderer — SwiftUI is the point of the file.
        "SessionPDFExporter.swift",
        // TODO: imports SwiftUI only for ObservableObject/@Published —
        // switch to `import Combine` and remove from this allowlist.
        "GatewayClientWrapper.swift",
        // TODO: same — ObservableObject only; swap to Combine.
        "SkillCache.swift",
        // TODO: same — ObservableObject only; swap to Combine.
        "SkillStore.swift",
        // TODO: same — ObservableObject only; swap to Combine.
        "TTSService.swift",
    ]

    @Test("Services do not import SwiftUI (except the allowlist)")
    func servicesDoNotImportSwiftUI() throws {
        let servicesDir = Self.sourcesRoot.appendingPathComponent("Services")
        var offenders: [String] = []
        for file in Self.swiftFiles(under: servicesDir) {
            guard !Self.swiftUIServiceAllowlist.contains(file.lastPathComponent) else { continue }
            let contents = try String(contentsOf: file, encoding: .utf8)
            let importsSwiftUI = contents
                .components(separatedBy: .newlines)
                .contains { $0.trimmingCharacters(in: .whitespaces) == "import SwiftUI" }
            if importsSwiftUI {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Services are the platform-agnostic layer — importing SwiftUI drags \
            presentation concerns below the ViewModel boundary and breaks reuse \
            in non-UI contexts. Offenders: \(offenders.joined(separator: ", ")). \
            If a service legitimately needs SwiftUI, add it to \
            swiftUIServiceAllowlist here AND the no_swiftui_in_services excluded \
            list in .swiftlint.yml, with a justification comment.
            """
        )
    }

    // MARK: - ViewModels must not construct Views

    /// ViewModels constructing View types inverts the dependency direction —
    /// the audit (2026-07) found only comment/doc mentions of View names in
    /// ViewModels, no constructions, so this checks the enforceable thing:
    /// no `SomethingView(` initializer call on a non-comment line.
    @Test("ViewModels do not construct View types")
    func viewModelsDoNotConstructViews() throws {
        let viewModelsDir = Self.sourcesRoot.appendingPathComponent("ViewModels")
        let constructionPattern = try NSRegularExpression(
            pattern: #"\b[A-Z][A-Za-z]*View\("#
        )
        var offenders: [String] = []
        for file in Self.swiftFiles(under: viewModelsDir) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for (index, rawLine) in contents.components(separatedBy: .newlines).enumerated() {
                // Strip line comments so doc references ("wired by ContentView")
                // don't trip the rule; block comments in VMs are rare enough
                // that a hit inside one is worth a human look anyway.
                let line = rawLine.components(separatedBy: "//").first ?? rawLine
                let range = NSRange(line.startIndex..., in: line)
                if constructionPattern.firstMatch(in: line, range: range) != nil {
                    offenders.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            ViewModels must not construct Views — that inverts the layer \
            direction (Views own ViewModels, never the reverse) and makes the \
            VM untestable without a UI. Offenders: \
            \(offenders.joined(separator: ", "))
            """
        )
    }

    // MARK: - No Utils/ directory

    @Test("Utils/ does not exist — Utilities/ is the one helpers directory")
    func noUtilsDirectory() {
        let utilsDir = Self.sourcesRoot.appendingPathComponent("Utils")
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: utilsDir.path,
            isDirectory: &isDirectory
        )
        #expect(
            !exists,
            """
            Sources/HermesNative/Utils/ must not exist — two helper directories \
            (Utils/ and Utilities/) meant every contributor guessed where shared \
            code lived; everything was merged into Utilities/. Move new helpers \
            there instead.
            """
        )
    }

    // MARK: - GatewayEvent wire types are documented

    @Test("Every GatewayEvent wire type appears in docs/rpc-reference.md")
    func gatewayEventCasesAreDocumented() throws {
        let eventFile = Self.sourcesRoot
            .appendingPathComponent("Models/GatewayEvent.swift")
        let source = try String(contentsOf: eventFile, encoding: .utf8)

        // Extract the type strings from the decode switch: every quoted string
        // in a `case "x.y":` (including multi-pattern cases separated by commas).
        guard let switchStart = source.range(of: "switch type {") else {
            Issue.record("Could not find the `switch type {` decode switch in GatewayEvent.swift — if from(type:) was restructured, update this test's parser.")
            return
        }
        let switchBody = String(source[switchStart.upperBound...])
        let casePattern = try NSRegularExpression(pattern: #"case\s+((?:"[^"]+"\s*,?\s*)+):"#)
        let quotedPattern = try NSRegularExpression(pattern: #""([^"]+)""#)

        var wireTypes: [String] = []
        let bodyRange = NSRange(switchBody.startIndex..., in: switchBody)
        casePattern.enumerateMatches(in: switchBody, range: bodyRange) { match, _, _ in
            guard let match, let patternRange = Range(match.range(at: 1), in: switchBody) else { return }
            let patterns = String(switchBody[patternRange])
            let innerRange = NSRange(patterns.startIndex..., in: patterns)
            quotedPattern.enumerateMatches(in: patterns, range: innerRange) { inner, _, _ in
                guard let inner, let nameRange = Range(inner.range(at: 1), in: patterns) else { return }
                wireTypes.append(String(patterns[nameRange]))
            }
        }
        #expect(
            wireTypes.count > 20,
            "Parsed only \(wireTypes.count) wire types from GatewayEvent.swift — the decode-switch parser is probably out of sync with the file's structure."
        )

        let docFile = Self.repoRoot.appendingPathComponent("docs/rpc-reference.md")
        let doc = try String(contentsOf: docFile, encoding: .utf8)
        let undocumented = wireTypes.filter { !doc.contains("`\($0)`") }
        #expect(
            undocumented.isEmpty,
            """
            docs/rpc-reference.md is the contract clients and the gateway are \
            built against — every event GatewayEvent decodes must have a row \
            there or the doc silently rots. Undocumented wire types: \
            \(undocumented.joined(separator: ", ")). Add a `wire type` row to \
            the events tables in docs/rpc-reference.md.
            """
        )
    }
}
