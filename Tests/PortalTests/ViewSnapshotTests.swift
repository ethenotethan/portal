import Testing
import SwiftUI
@testable import Portal

/// View-snapshot gate. Each test renders a pure-presentation View to a PNG and
/// compares it against a committed golden (see ViewSnapshot for why goldens are
/// recorded on CI, not locally). Under SNAPSHOT_RECORD=1 the tests rewrite the
/// goldens instead of asserting — that's how a golden is (re)generated.
///
/// Scope note: only Views that render deterministically from plain value inputs
/// belong here — no ViewModel wiring, no `.task`/`.onAppear` that mutates state,
/// no animation. Those are the Views a headless render can pin. Environment-
/// coupled Views stay out of the gate until they're refactored to take values.
@Suite("View snapshots")
internal struct ViewSnapshotTests {

    /// Assert a snapshot outcome.
    ///
    /// `.mismatch` and `.renderFailed` fail the test — those are real
    /// regressions. `.missingGolden` is deliberately NON-fatal: goldens are born
    /// on CI (see ViewSnapshot), so before the record workflow has run — locally,
    /// and on the very PR that introduces a new snapshot — no golden exists yet,
    /// and failing here would make the infra impossible to land. It's logged
    /// loudly instead so the "record → commit → verify" loop is visible. Once a
    /// golden is committed, a later deletion shows up as a removed file in the
    /// diff (reviewable), and any content drift trips `.mismatch` (fatal).
    @MainActor
    private func expect(_ view: some View, _ name: String, size: CGSize) {
        switch ViewSnapshot.verify(view, name: name, size: size) {
        case .recorded:
            // Recording run — nothing to assert; the artifact is the output.
            break
        case .match:
            break
        case .missingGolden:
            print("⚠︎ snapshot: no golden for '\(name)' yet — generate it with "
                  + "the snapshot-record workflow on CI, then commit "
                  + "Tests/PortalTests/__Snapshots__/\(name).png. (non-fatal)")
        case let .mismatch(fraction):
            let pct = round(fraction * 10000) / 100
            let msg = "Snapshot '\(name)' changed: \(pct)% of pixels differ "
                + "beyond tolerance. If intentional, re-record the golden."
            Issue.record(Comment(rawValue: msg))
        case .renderFailed:
            Issue.record(Comment(rawValue: "Snapshot '\(name)' failed to render."))
        }
    }

    @Test("GitHubLinkCard — pull request")
    @MainActor
    internal func gitHubLinkCardPullRequest() {
        let url = URL(string: "https://github.com/ethenotethan/portal/pull/11")!
        let link = GitHubLink(url: url)
        #expect(link != nil, "fixture URL should parse into a GitHubLink")
        guard let link else { return }
        expect(GitHubLinkCard(link: link), "github-link-card-pr", size: CGSize(width: 320, height: 72))
    }

    @Test("GitHubLinkCard — repository")
    @MainActor
    internal func gitHubLinkCardRepository() {
        let url = URL(string: "https://github.com/ethenotethan/portal")!
        guard let link = GitHubLink(url: url) else {
            Issue.record("fixture URL should parse")
            return
        }
        expect(GitHubLinkCard(link: link), "github-link-card-repo", size: CGSize(width: 320, height: 72))
    }

    // MARK: - Graphs section switcher

    private static let switcherSize = CGSize(width: 220, height: 32)

    // `GraphSurfaceTitle`, not `GraphSurfaceMenu`: the menu itself needs AppKit's
    // menu hosting and renders as an unavailable-content placeholder here, so a
    // golden of the control would be a blank box. The title is the part a reader
    // sees, and it renders from a plain value — exactly this gate's scope.

    @Test("GraphSurfaceTitle — wiki selected")
    @MainActor
    internal func graphSurfaceTitleWiki() {
        expect(
            GraphSurfaceTitle(surface: .wiki),
            "graph-surface-title-wiki",
            size: Self.switcherSize
        )
    }

    @Test("GraphSurfaceTitle — runtime graph selected")
    @MainActor
    internal func graphSurfaceTitleRuntime() {
        expect(
            GraphSurfaceTitle(surface: .runtime),
            "graph-surface-title-runtime",
            size: Self.switcherSize
        )
    }

    /// The goldens above are born on CI, so until they exist neither test can
    /// fail — and a switcher that renders the *same* thing for both graphs (a
    /// title wired to the wrong side of the binding) would slip through. Compare
    /// the two renders directly: they must both draw, and they must differ.
    @Test("the switcher renders each graph's own title")
    @MainActor
    internal func graphSurfaceTitleReflectsSelection() {
        let wiki = ViewSnapshot.png(GraphSurfaceTitle(surface: .wiki), size: Self.switcherSize)
        let runtime = ViewSnapshot.png(GraphSurfaceTitle(surface: .runtime), size: Self.switcherSize)

        #expect(wiki != nil, "the switcher should render with the wiki graph selected")
        #expect(runtime != nil, "the switcher should render with the runtime graph selected")
        #expect(wiki != runtime, "the switcher must show the selected graph's label, not a fixed one")
    }
}
