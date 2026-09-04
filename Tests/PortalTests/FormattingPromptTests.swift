import Testing
import Foundation
@testable import Portal

/// Render contracts live in the client prompt — the gateway teaches the agent
/// nothing about Portal's surfaces. These pin the parts of the prompt that
/// pair with host-side input handling, where silent drift produces artifacts
/// that fight the host instead of failing visibly.
@Suite("App formatting prompt")
@MainActor
internal struct FormattingPromptTests {
    private var prompt: String { ChatViewModel.appFormattingPrompt }

    @Test("teaches the Pointer Lock input contract for interactive HTML worlds")
    internal func teachesPointerLockContract() {
        // The host captures the mouse (HTMLPointerLockBridge) and hides the
        // cursor, so a generated world using click-and-drag as its primary
        // camera scheme is unusable — the exact "having to click and drag when
        // I shouldn't" complaint. The prompt must steer generation toward
        // movementX/movementY while locked.
        #expect(prompt.contains("movementX"))
        #expect(prompt.contains("pointerLockElement"))
        #expect(prompt.contains("NEVER implement click-and-drag camera controls"))
    }

    @Test("teaches keyboard movement and the host's Escape ownership")
    internal func teachesKeyboardContract() {
        // keydown/keyup on document — the canvas is not guaranteed focus.
        #expect(prompt.contains("keydown"))
        #expect(prompt.contains("WASD"))
        // Esc is two-stage host chrome (release, then exit); a world that
        // binds it fights the release gesture.
        #expect(prompt.contains("Do not bind Escape"))
    }

    @Test("teaches HUD overlays to pass clicks through to the scene")
    internal func teachesHUDPassthrough() {
        // The capture bridge falls back to the dominant canvas, but overlays
        // that swallow pointer events still block direct canvas interaction —
        // pointer-events: none is the belt to the bridge's suspenders.
        #expect(prompt.contains("pointer-events: none"))
    }

    // MARK: - Advertised set vs renderable set

    /// Every native block kind the app can render, read out of the dispatch that
    /// renders them rather than from a list kept alongside it.
    ///
    /// `MarkdownContentView`'s fence dispatch calls
    /// `.captureLivingArtifact(kind: "…")` exactly once per native kind, so those
    /// call sites ARE the renderable set. Deriving the set from source is what
    /// makes the test below self-maintaining: a new fence starts failing it the
    /// moment it is rendered, with no second list to remember to update.
    private func renderableKindsFromDispatch() throws -> Set<String> {
        // …/Tests/PortalTests/FormattingPromptTests.swift → repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PortalTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let dispatch = root
            .appendingPathComponent("Sources/Portal/Views/MarkdownContentView.swift")
        let source = try String(contentsOf: dispatch, encoding: .utf8)

        let regex = try NSRegularExpression(pattern: #"captureLivingArtifact\(kind: "([a-z0-9]+)""#)
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let kinds = Set(matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[range])
        })
        // A refactor that moves the dispatch elsewhere must not silently turn
        // this test into a no-op that passes over an empty set.
        #expect(kinds.count >= 11, "expected to find the native fence dispatch in \(dispatch.lastPathComponent)")
        return kinds
    }

    /// The regression this catches: `kanban`, `checklist` and `calendar` shipped
    /// fully rendered, action-wired and merge-aware, but were never named in the
    /// prompt — so no agent knew they existed and none was ever emitted. Asked
    /// for a board, an agent reads this prompt, concludes Portal has no board
    /// primitive, and offers to hand-roll one in HTML. An implemented surface the
    /// model is never told about is a dead surface, and nothing failed to say so.
    @Test("advertises every native block kind the app renders")
    internal func advertisesEveryRenderableKind() throws {
        let renderable = try renderableKindsFromDispatch()
        for kind in renderable.sorted() {
            #expect(
                prompt.contains("```\(kind)"),
                "the app renders ```\(kind) blocks but the prompt never mentions the fence"
            )
        }
    }

    /// Board/list/calendar kinds are only worth advertising if the agent is also
    /// told they are persistent and that the user edits them — otherwise it emits
    /// one as a throwaway table and re-sends it without an id.
    @Test("teaches the board, checklist and calendar fences with their semantics")
    internal func teachesStatefulBoardKinds() {
        for fence in ["```kanban", "```checklist", "```calendar"] {
            #expect(prompt.contains(fence))
        }
        // Columns and cards, not a status column on a table.
        #expect(prompt.contains("\"columns\": [\"Todo\", \"Doing\", \"Done\"]"))
        #expect(prompt.contains("\"type\": \"kanban\""))
        #expect(prompt.contains("\"column\": \"status\""))
        #expect(prompt.contains("interactive Kanban"))
        // The move/toggle round-trip needs no declared action, and saying so
        // stops the agent bolting a redundant "actions" array onto a board.
        #expect(prompt.contains("no \"actions\" declaration"))
        // The fence is shared with mermaid's kanban diagram; only the JSON form
        // reaches the native board (see MarkdownParser.isKanbanBlock).
        #expect(prompt.contains("also a mermaid diagram type"))
        // Field-level merge is the non-obvious part: a re-emit that omits `done`
        // or `column` must not be read as clearing the user's edit.
        #expect(prompt.contains("PRESERVE THE USER'S OWN"))
    }

    @Test("teaches the native blueprint fence and placement contract")
    internal func teachesBlueprints() {
        #expect(prompt.contains("```blueprint"))
        #expect(prompt.contains("explicit placement"))
        #expect(prompt.contains("\"elements\""))
        #expect(prompt.contains("\"connections\""))
        #expect(prompt.contains("0–100"))
    }
}
