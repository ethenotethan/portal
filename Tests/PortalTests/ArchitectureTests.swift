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
        .deletingLastPathComponent() // Tests/PortalTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repo root

    private static let sourcesRoot = repoRoot
        .appendingPathComponent("Sources/Portal")

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

    // MARK: - Generation counters must be compared

    /// The generation-counter idiom (bump an Int before an `await`, capture it
    /// into a local, then `guard captured == self.counter else { return }` after
    /// every await so stale completions are discarded) recurs across the async
    /// ViewModels — `loadGeneration`, `settleGeneration`, `physicsGeneration`
    /// (WikiGraphViewModel), `loadGeneration` (WikiTimelineViewModel),
    /// `refreshGeneration` (SessionListViewModel), `sessionSwitchGeneration`
    /// (ChatViewModel). It was copy-paste consistency with nothing enforcing it:
    /// bump the counter but forget the `==` guard after a new await, and a slow
    /// older response silently overwrites a newer one.
    ///
    /// This is the enforceable half of that invariant: a counter that is
    /// incremented MUST also be compared with `==` somewhere in the same file. A
    /// bumped-but-never-compared counter is either a dead bump or — the bug —
    /// a guard that was never written. Regex-per-line can't see this (bump and
    /// compare live on different lines), which is why it's a test, not a
    /// SwiftLint rule; the line-local slice (no ordering comparison on a
    /// generation token) is the `no_ordering_comparison_on_generation` lint rule.
    ///
    /// `@Published` generation counters are deliberately EXEMPT: those are
    /// externally-observed navigation signals (e.g. `createGeneration`, which
    /// `ContentView` watches via `.onChange` to push a new session). Their
    /// comparison is legitimately cross-file, so an in-file `==` check would be
    /// wrong to require. The `@Published` marker is the structural discriminator
    /// between the two roles — no name allowlist needed.
    @Test("Generation counters that are bumped are also compared (drop-stale guard)")
    private func generationCountersMustBeCompared() throws {
        // Scan the async layers where the idiom lives. Services is included so a
        // future integrator that grows a generation counter is covered too.
        let dirs = ["ViewModels", "Services"].map(Self.sourcesRoot.appendingPathComponent)
        let declPattern = try NSRegularExpression(pattern: #"\bvar\s+(\w+Generation)\b"#)
        var offenders: [String] = []

        for dir in dirs {
            for file in Self.swiftFiles(under: dir) {
                let contents = try String(contentsOf: file, encoding: .utf8)
                let lines = contents.components(separatedBy: .newlines)

                // Collect stale-drop counters: `var …Generation`, excluding
                // @Published ones (externally-observed signals — see above).
                var counters: Set<String> = []
                for rawLine in lines {
                    let line = rawLine.components(separatedBy: "//").first ?? rawLine
                    let range = NSRange(line.startIndex..., in: line)
                    guard let match = declPattern.firstMatch(in: line, range: range),
                          let nameRange = Range(match.range(at: 1), in: line) else { continue }
                    if line.contains("@Published") { continue }
                    counters.insert(String(line[nameRange]))
                }

                // For each counter, a bump (`name +=`) obliges a compare
                // (a non-decl line mentioning the name and containing `==`).
                for name in counters.sorted() {
                    let isBumped = lines.contains { line in
                        line.range(of: #"\b\#(NSRegularExpression.escapedPattern(for: name))\s*\+="#,
                                   options: .regularExpression) != nil
                    }
                    guard isBumped else { continue } // reserved / not yet wired — not a stale-drop guard

                    let isCompared = lines.contains { line in
                        let code = line.components(separatedBy: "//").first ?? line
                        guard code.contains(name), code.contains("==") else { return false }
                        // Exclude the declaration line itself (`var x = 0` has no ==,
                        // so this is belt-and-suspenders) and require the == to sit
                        // adjacent to the counter name, not merely co-occur.
                        return code.range(
                            of: #"\#(NSRegularExpression.escapedPattern(for: name))\s*==|==\s*(?:self\.)?\#(NSRegularExpression.escapedPattern(for: name))"#,
                            options: .regularExpression
                        ) != nil
                    }
                    if !isCompared {
                        offenders.append("\(file.lastPathComponent): \(name)")
                    }
                }
            }
        }

        #expect(
            offenders.isEmpty,
            """
            A generation counter is bumped but never compared with `==` in the \
            same file. The drop-stale idiom is: bump before the await, capture \
            `let generation = counter`, then \
            `guard generation == self.counter else { return }` after EVERY await \
            so a slow older response can't overwrite a newer one. Bumping without \
            that guard is the exact stale-overwrite bug this idiom exists to \
            prevent. Offenders: \(offenders.joined(separator: ", ")). \
            (If the counter is an externally-observed signal compared cross-file, \
            mark it @Published like createGeneration.)
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
            Sources/Portal/Utils/ must not exist — two helper directories \
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

    // MARK: - Monospaced text survives the app-wide typeface

    /// Files whose monospaced text is defended by an ancestor view rather than
    /// at each `.font(...)` site, with the reason. A container-level
    /// `.monospaced()` covers everything below it, so repeating it per site
    /// would be noise — but it also can't be seen by the line-window check
    /// below, which is why each one is listed here on purpose.
    private static let containerMonospacedAllowlist: [String: String] = [
        // The whole HUD gets one `.monospaced()` on its outer VStack: every row
        // is a column of numbers that would jitter as the values change.
        "PerfOverlayView.swift": "the overlay VStack re-asserts .monospaced() once",
        // `tableCell` and `CodeBlockView` re-assert at the view level. The
        // `Font`-valued sites here are inputs to those, and the inline-code
        // runs are a documented limitation: no AttributedString run font
        // survives a root .fontDesign.
        "MarkdownContentView.swift": "tableCell and CodeBlockView re-assert; inline runs documented as a known limitation",
        // `cell(text:isHeader:)` re-asserts with `.monospaced(isHeader)`.
        "ExportPrimitives.swift": "cell(text:isHeader:) re-asserts .monospaced(isHeader)",
    ]

    @Test("monospaced text re-asserts itself against the app-wide typeface")
    internal func monospacedSitesSurviveTheAppFont() throws {
        // The selected `AppFontTheme` is applied as a root `.fontDesign(_:)`,
        // which *overrides* a `design:` written inside a site's own
        // `.font(.system(..., design: .monospaced))`. Only a view-level
        // `.monospaced()` wins it back. So a site that asks for monospaced and
        // does not re-assert silently loses its aligned columns the moment a
        // user picks Serif — and nothing about the code looks wrong.
        var undefended: [String] = []

        for file in Self.swiftFiles(under: Self.sourcesRoot) {
            let name = file.lastPathComponent
            let source = try String(contentsOf: file, encoding: .utf8)
            guard source.contains("design: .monospaced") else { continue }
            if Self.containerMonospacedAllowlist[name] != nil { continue }

            let lines = source.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("design: .monospaced") {
                // The re-assert usually sits on the next line, but a
                // `.foregroundStyle` or a wrapped argument list can intervene.
                let window = lines[index..<min(index + 3, lines.count)].joined(separator: "\n")
                if window.contains(".monospaced(") { continue }
                undefended.append("\(name):\(index + 1)")
            }
        }

        #expect(
            undefended.isEmpty,
            """
            These sites ask for `design: .monospaced` but never re-assert it at \
            the view level, so the app-wide typeface (a root `.fontDesign`) \
            overrides them and their columns stop aligning: \
            \(undefended.joined(separator: ", ")). Add `.monospaced()` after the \
            `.font(...)`, or — if an ancestor view already covers the whole \
            surface — add the file to `containerMonospacedAllowlist` with the \
            reason. See `AppFontSettingsSection`.
            """
        )
    }

    @Test("the container-level monospaced allowlist has no stale entries")
    internal func containerMonospacedAllowlistIsCurrent() throws {
        // An entry that outlives its file, or its file's last monospaced site,
        // is a hole in the rule above that reads like coverage.
        for (name, reason) in Self.containerMonospacedAllowlist {
            let matches = Self.swiftFiles(under: Self.sourcesRoot)
                .filter { $0.lastPathComponent == name }
            guard let file = matches.first else {
                Issue.record("containerMonospacedAllowlist names \(name), which no longer exists under Sources/Portal — remove the entry.")
                continue
            }
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(
                source.contains("design: .monospaced"),
                "\(name) has no `design: .monospaced` sites left — remove it from containerMonospacedAllowlist."
            )
            // The exemption is only honest if the ancestor really does
            // re-assert. Every reason on the list claims one.
            #expect(
                source.contains(".monospaced("),
                "\(name) is exempted because \(reason), but the file contains no `.monospaced(` call at all."
            )
        }
    }
}
