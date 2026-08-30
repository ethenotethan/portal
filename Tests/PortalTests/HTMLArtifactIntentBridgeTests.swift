import Foundation
import Testing
@testable import Portal

@Suite("HTML artifact intent bridge")
internal struct HTMLArtifactIntentBridgeTests {
    @Test("decodes only the narrow invoke URL contract")
    internal func decodesInvokeURL() throws {
        let url = try #require(URL(string: "hermes-artifact-action://invoke?binding_id=start-issue&entity_ref=issues%2FARC-42&nonce=test-nonce"))
        let request = try #require(HTMLArtifactIntentRequest(url: url, expectedNonce: "test-nonce"))

        #expect(request == HTMLArtifactIntentRequest(
            bindingID: "start-issue",
            entityRef: "issues/ARC-42"
        ))
    }

    @Test("rejects ordinary links, forged capabilities, duplicate fields, and missing bindings")
    internal func rejectsAnythingOutsideContract() throws {
        let urls = [
            "https://linear.app/ARC-42",
            "hermes-artifact-action://delete?binding_id=x&nonce=test-nonce",
            "hermes-artifact-action://invoke?entity_ref=ARC-42&nonce=test-nonce",
            "hermes-artifact-action://invoke?binding_id=start-issue",
            "hermes-artifact-action://invoke?binding_id=start-issue&nonce=wrong-nonce",
            "hermes-artifact-action://invoke?binding_id=start-issue&binding_id=complete-issue&nonce=test-nonce",
            "hermes-artifact-action://invoke?binding_id=start-issue&nonce=test-nonce&unexpected=value",
        ]
        for raw in urls {
            let url = try #require(URL(string: raw))
            #expect(HTMLArtifactIntentRequest(url: url, expectedNonce: "test-nonce") == nil)
        }
    }

    @Test("binding IDs are bounded and use stable identifier characters")
    internal func validatesBindingIDs() throws {
        let spaced = try #require(URL(string: "hermes-artifact-action://invoke?binding_id=start%20issue&nonce=test-nonce"))
        #expect(HTMLArtifactIntentRequest(url: spaced, expectedNonce: "test-nonce") == nil)

        let oversized = String(repeating: "a", count: 129)
        let url = try #require(URL(string: "hermes-artifact-action://invoke?binding_id=\(oversized)&nonce=test-nonce"))
        #expect(HTMLArtifactIntentRequest(url: url, expectedNonce: "test-nonce") == nil)
    }

    @Test("entity references reject control characters")
    internal func rejectsControlCharactersInEntityReferences() throws {
        let url = try #require(URL(string: "hermes-artifact-action://invoke?binding_id=start-issue&entity_ref=issues%2FARC-42%0Aforged&nonce=test-nonce"))

        #expect(HTMLArtifactIntentRequest(url: url, expectedNonce: "test-nonce") == nil)
    }

    @Test("resolves only declared intent actions")
    internal func resolvesDeclaredIntent() {
        let actions = ArtifactAction.parse([
            ["type": "intent", "id": "start-issue", "label": "Start", "intent": "linear.issue.start"],
            ["type": "toggle", "field": "selected"],
        ])
        let valid = HTMLArtifactIntentRequest(bindingID: "start-issue", entityRef: "issues/ARC-42")
        let forged = HTMLArtifactIntentRequest(bindingID: "delete-everything", entityRef: "issues/ARC-42")

        #expect(HTMLArtifactIntentBridge.resolve(valid, actions: actions)?.bindingID == "start-issue")
        #expect(HTMLArtifactIntentBridge.resolve(forged, actions: actions) == nil)
    }

    @Test("injected bridge recognizes inert attributes and carries an isolated capability")
    internal func bridgeScriptIsNarrow() {
        let script = HTMLArtifactIntentBridge.userScriptSource(nonce: "test-nonce")

        #expect(script.contains("data-hermes-binding"))
        #expect(script.contains("data-hermes-entity"))
        #expect(script.contains("event.isTrusted"))
        #expect(script.contains("hermes-artifact-action://invoke"))
        #expect(script.contains("test-nonce"))
        #expect(!script.contains("webkit.messageHandlers"))
        #expect(!script.contains("GatewayClient"))
        #expect(!script.contains("fetch("))
    }

    // MARK: - StatusMark

    @Test("every invocation state maps to its fixed reflection token")
    @MainActor
    internal func invocationStatesMapToStatusTokens() {
        let cases: [(ArtifactStore.IntentInvocationState, HTMLArtifactIntentBridge.StatusToken)] = [
            (.pending, .pending),
            (.needsConfirmation(challenge: "challenge", prompt: "Confirm?"), .needsConfirmation),
            (.succeeded(message: "Done", sessionID: "session-1"), .succeeded),
            (.failed(reason: "Unavailable"), .failed),
            (.conflict, .conflict),
            (.unsupported(reason: nil), .unsupported),
        ]

        for (state, expectedToken) in cases {
            #expect(HTMLArtifactIntentBridge.StatusToken(state) == expectedToken)
        }
    }

    @Test("StatusMark stores its slot and token and is Equatable on all fields")
    internal func statusMarkConstruction() {
        let a = HTMLArtifactIntentBridge.StatusMark(
            bindingID: "start-issue", entityRef: "issues/ARC-42", status: .pending)
        #expect(a.bindingID == "start-issue")
        #expect(a.entityRef == "issues/ARC-42")
        #expect(a.status == .pending)

        // Equality is structural: any field differing breaks it, so a stale mark
        // set is detected and the host view re-runs the reflection JS.
        let sameSlotOtherStatus = HTMLArtifactIntentBridge.StatusMark(
            bindingID: "start-issue", entityRef: "issues/ARC-42", status: .succeeded)
        #expect(a != sameSlotOtherStatus)

        let otherEntity = HTMLArtifactIntentBridge.StatusMark(
            bindingID: "start-issue", entityRef: "issues/ARC-99", status: .pending)
        #expect(a != otherEntity)

        let otherBinding = HTMLArtifactIntentBridge.StatusMark(
            bindingID: "complete-issue", entityRef: "issues/ARC-42", status: .pending)
        #expect(a != otherBinding)
    }

    @Test("an empty entityRef is a distinct slot from a named one")
    internal func statusMarkEmptyEntityDistinct() {
        // Controls without a data-hermes-entity match on the empty string; a
        // row-scoped button and a header-scoped one with the same bindingID must
        // not cross-talk.
        let header = HTMLArtifactIntentBridge.StatusMark(
            bindingID: "start-issue", entityRef: "", status: .pending)
        let row = HTMLArtifactIntentBridge.StatusMark(
            bindingID: "start-issue", entityRef: "issues/ARC-42", status: .pending)
        #expect(header != row)
    }

    // MARK: - statusReflectionScript

    @Test("reflection script embeds the slot and status as JSON literals")
    internal func reflectionScriptStampsStatus() {
        let js = HTMLArtifactIntentBridge.statusReflectionScript(
            bindingID: "start-issue", entityRef: "issues/ARC-42", status: .succeeded)

        // The binding/entity are embedded via JSONEncoder, which escapes the
        // forward slash as \/; the token is the status's rawValue so it
        // round-trips as the CSS hook. A non-nil status drives setAttribute.
        #expect(js.contains(#"const binding = "start-issue";"#))
        #expect(js.contains(#"const entity = "issues\/ARC-42";"#))
        #expect(js.contains(#"const status = "succeeded";"#))
        // A concrete status means status !== null, so setAttribute is the live
        // branch — assert the token arrives there.
        #expect(js.contains(#"node.setAttribute('data-hermes-status', status);"#))
    }

    @Test("a nil status resolves to null and drives the clear branch")
    internal func reflectionScriptClearsWhenNil() {
        let js = HTMLArtifactIntentBridge.statusReflectionScript(
            bindingID: "start-issue", entityRef: "", status: nil)

        // status === null is what selects removeAttribute at runtime; the
        // template carries both branches, so this is the meaningful assertion.
        #expect(js.contains("const status = null;"))
        #expect(js.contains("node.removeAttribute('data-hermes-status');"))
    }

    @Test("characters that would break out of a JS literal are JSON-escaped")
    internal func reflectionScriptEscapesAdversarialStrings() {
        // A binding carrying a closing quote / script tag must not be able to
        // escape the string literal jsStringLiteral wraps it in. JSONEncoder
        // turns `"` into `\"`, so the surrounding quotes stay balanced.
        let adversarial = #"</script>""#
        let js = HTMLArtifactIntentBridge.statusReflectionScript(
            bindingID: adversarial, entityRef: adversarial, status: .failed)

        // The embedded literal escapes the quote (backslash-quote), never a
        // bare quote that could terminate the JS string.
        #expect(js.contains(#"\""#))
        // The status token is still intact and well-formed.
        #expect(js.contains(#"const status = "failed";"#))
    }

    @Test("the needs-confirmation rawValue carries its hyphen through reflection")
    internal func reflectionScriptPreservesHyphenatedToken() {
        let js = HTMLArtifactIntentBridge.statusReflectionScript(
            bindingID: "x", entityRef: "", status: .needsConfirmation)
        #expect(js.contains(#"const status = "needs-confirmation";"#))
    }
}
