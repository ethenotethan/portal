import Foundation
import Testing
@testable import HermesNative

// Pure coverage for the native→page status write-back and the intent→session
// click-through: the reflection JS builder (value-in / string-out, same shape
// as userScriptSource), the StatusToken projection of store state, the slot
// decode the host uses to build marks, and the session-switch notification
// mapping. No WebView, no gateway.

@Suite("Artifact status reflection + session link")
internal struct ArtifactStatusReflectionTests {

    // MARK: - statusReflectionScript

    @Test("Reflection script stamps the status and targets both binding + entity")
    internal func reflectionScriptStamps() {
        let js = HTMLArtifactIntentBridge.statusReflectionScript(
            bindingID: "archive", entityRef: "ARC-42", status: .succeeded)
        #expect(js.contains("data-hermes-status"))
        #expect(js.contains("data-hermes-binding"))
        #expect(js.contains("data-hermes-entity"))
        #expect(js.contains("\"archive\""))     // binding JSON-encoded
        #expect(js.contains("\"ARC-42\""))      // entity JSON-encoded
        #expect(js.contains("\"succeeded\""))   // token JSON-encoded
        #expect(js.contains("setAttribute"))
        // Never a native→page execution surface.
        #expect(!js.contains("innerHTML"))
        #expect(!js.contains("fetch("))
        #expect(!js.contains("eval("))
    }

    @Test("A nil status clears the attribute rather than stamping one")
    internal func reflectionScriptClears() {
        let js = HTMLArtifactIntentBridge.statusReflectionScript(
            bindingID: "archive", entityRef: "", status: nil)
        #expect(js.contains("removeAttribute"))
        #expect(js.contains("const status = null"))
    }

    @Test("Binding and entity strings are JSON-encoded so they can't break out of JS")
    internal func reflectionScriptEscapesInjection() {
        let js = HTMLArtifactIntentBridge.statusReflectionScript(
            bindingID: "a\";evil()//", entityRef: "b</script>", status: .failed)
        // The dangerous characters survive only inside an escaped JS string
        // literal — the raw breakout sequence never appears unescaped.
        #expect(!js.contains("evil()//\n"))
        #expect(js.contains("\\\""))            // the embedded quote is escaped
    }

    @Test("Every store state projects to a status token")
    internal func statusTokenProjection() {
        #expect(HTMLArtifactIntentBridge.StatusToken(.pending) == .pending)
        #expect(HTMLArtifactIntentBridge.StatusToken(
            .needsConfirmation(challenge: "c", prompt: "p")) == .needsConfirmation)
        #expect(HTMLArtifactIntentBridge.StatusToken(
            .succeeded(message: "m", sessionID: "s")) == .succeeded)
        #expect(HTMLArtifactIntentBridge.StatusToken(.failed(reason: "r")) == .failed)
        #expect(HTMLArtifactIntentBridge.StatusToken(.conflict) == .conflict)
        #expect(HTMLArtifactIntentBridge.StatusToken(.unsupported) == .unsupported)
    }

    @Test("needs-confirmation token uses a CSS-friendly hyphenated raw value")
    internal func statusTokenRawValues() {
        #expect(HTMLArtifactIntentBridge.StatusToken.needsConfirmation.rawValue == "needs-confirmation")
    }

    // MARK: - ArtifactStore.intentSlots — decode composite keys

    @MainActor
    @Test("intentSlots decodes binding + entity back out of the composite slot key")
    internal func intentSlotsDecode() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-reflect-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ArtifactStore(fileURL: dir.appendingPathComponent("artifacts.json"))
        store.seedArtifactForTesting(LivingArtifact(
            id: "issues", kind: "html", title: "Issues", content: "{}",
            updatedAt: Date(timeIntervalSince1970: 0), updatedBy: "test", rev: 1))

        // An entry key that itself contains a slash — the decode must split on
        // the FIRST separator after the artifact prefix only.
        store.seedIntentStateForTesting(
            artifactID: "issues", bindingID: "archive", entryKey: "issues/ARC-42",
            state: .succeeded(message: "done", sessionID: nil))

        let slots = store.intentSlots(artifactID: "issues")
        let match = try? #require(slots.first)
        #expect(match?.bindingID == "archive")
        #expect(match?.entryKey == "issues/ARC-42")
        // A slot for a different artifact never leaks in.
        #expect(store.intentSlots(artifactID: "other").isEmpty)
    }

    // MARK: - ArtifactIntentSessionLink

    @Test("Session link builds the in-process switch notification")
    internal func sessionLinkNotification() throws {
        let n = try #require(ArtifactIntentSessionLink.switchNotification(sessionID: "  sess-abc  "))
        #expect(n.name == .hermesSwitchToSession)
        #expect(n.userInfo["session_id"] == "sess-abc")   // trimmed
    }

    @Test("A blank session id yields no notification and posts nothing")
    internal func sessionLinkBlankIsNoop() {
        #expect(ArtifactIntentSessionLink.switchNotification(sessionID: "   ") == nil)

        let center = NotificationCenter()
        var posted = 0
        let token = center.addObserver(
            forName: .hermesSwitchToSession, object: nil, queue: nil) { _ in posted += 1 }
        defer { center.removeObserver(token) }
        ArtifactIntentSessionLink.open(sessionID: "", center: center)
        #expect(posted == 0)
    }

    @Test("open posts a switch carrying the session id")
    internal func sessionLinkOpenPosts() {
        let center = NotificationCenter()
        var received: String?
        let token = center.addObserver(
            forName: .hermesSwitchToSession, object: nil, queue: nil) { note in
            received = note.userInfo?["session_id"] as? String
        }
        defer { center.removeObserver(token) }
        ArtifactIntentSessionLink.open(sessionID: "sess-xyz", center: center)
        #expect(received == "sess-xyz")
    }
}
