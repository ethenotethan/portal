import Foundation
import Testing
@testable import HermesNative

@Suite("HTML artifact intent bridge")
struct HTMLArtifactIntentBridgeTests {
    @Test("decodes only the narrow invoke URL contract")
    func decodesInvokeURL() throws {
        let url = try #require(URL(string: "hermes-artifact-action://invoke?binding_id=start-issue&entity_ref=issues%2FARC-42&nonce=test-nonce"))
        let request = try #require(HTMLArtifactIntentRequest(url: url, expectedNonce: "test-nonce"))

        #expect(request == HTMLArtifactIntentRequest(
            bindingID: "start-issue",
            entityRef: "issues/ARC-42"
        ))
    }

    @Test("rejects ordinary links, forged capabilities, duplicate fields, and missing bindings")
    func rejectsAnythingOutsideContract() throws {
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
    func validatesBindingIDs() throws {
        let spaced = try #require(URL(string: "hermes-artifact-action://invoke?binding_id=start%20issue&nonce=test-nonce"))
        #expect(HTMLArtifactIntentRequest(url: spaced, expectedNonce: "test-nonce") == nil)

        let oversized = String(repeating: "a", count: 129)
        let url = try #require(URL(string: "hermes-artifact-action://invoke?binding_id=\(oversized)&nonce=test-nonce"))
        #expect(HTMLArtifactIntentRequest(url: url, expectedNonce: "test-nonce") == nil)
    }

    @Test("resolves only declared intent actions")
    func resolvesDeclaredIntent() {
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
    func bridgeScriptIsNarrow() {
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
}
