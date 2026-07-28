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
}
