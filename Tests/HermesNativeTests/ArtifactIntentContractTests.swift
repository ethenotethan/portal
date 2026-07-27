import Foundation
import Testing
@testable import HermesNative

// Pure-function coverage for the artifact-intent contract: the manifest
// grammar (ArtifactAction.parse intent branch), the gateway record decode
// (LivingArtifact.from), the invoke-result status mapping
// (ArtifactActionInvokeResult.from), the ledger-outcome mapping
// (IntentInvocationState.from), and the entity_ref caps on the HTML bridge
// request. All value-in/value-out — no gateway, no WebView.

@Suite("Artifact intent contract (pure)")
internal struct ArtifactIntentContractTests {

    // MARK: - ArtifactAction.parse — the intent branch

    @Test("Intent action parses binding id, label, intent name, and role")
    internal func parseIntentFull() throws {
        let actions = ArtifactAction.parse([[
            "type": "intent", "id": "archive-issue", "label": "Archive",
            "intent": "linear.issue.archive", "presentation": ["role": "destructive"],
        ]])
        let action = try #require(actions.first)
        #expect(action.kind == .intent)
        #expect(action.bindingID == "archive-issue")
        #expect(action.label == "Archive")
        #expect(action.intentName == "linear.issue.archive")
        #expect(action.presentationRole == .destructive)
        #expect(action.id == "intent:archive-issue")
    }

    @Test("Intent label defaults to the binding id; role defaults to normal")
    internal func parseIntentDefaults() throws {
        let actions = ArtifactAction.parse([["type": "intent", "id": "refresh"]])
        let action = try #require(actions.first)
        #expect(action.label == "refresh")            // label defaults to id
        #expect(action.intentName.isEmpty)            // no intent name given
        #expect(action.presentationRole == .normal)   // default role
    }

    @Test("Intent with an empty id drops")
    internal func parseIntentEmptyIDDrops() {
        #expect(ArtifactAction.parse([["type": "intent", "id": "  "]]).isEmpty)
        #expect(ArtifactAction.parse([["type": "intent", "label": "x"]]).isEmpty)
    }

    @Test("Unknown presentation role falls back to normal")
    internal func parseIntentUnknownRole() throws {
        let actions = ArtifactAction.parse([[
            "type": "intent", "id": "x", "presentation": ["role": "explosive"],
        ]])
        #expect(try #require(actions.first).presentationRole == .normal)
    }

    // MARK: - ArtifactActionInvokeResult.from — all status branches

    @Test("Invoke result maps every status string to its outcome")
    internal func invokeResultStatusMapping() {
        func outcome(_ dict: [String: AnyCodable]?) -> ArtifactActionInvokeResult.Outcome {
            ArtifactActionInvokeResult.from(dict).outcome
        }

        if case .needsConfirmation(let c, let p) = outcome([
            "status": AnyCodable("needs_confirmation"),
            "challenge": AnyCodable("chal"), "prompt": AnyCodable("Sure?"),
        ]) {
            #expect(c == "chal")
            #expect(p == "Sure?")
        } else { Issue.record("expected needsConfirmation") }

        if case .succeeded(let m, let sid) = outcome([
            "status": AnyCodable("succeeded"), "message": AnyCodable("done"),
            "session_id": AnyCodable("sess-1"),
        ]) {
            #expect(m == "done")
            #expect(sid == "sess-1")   // ran as a contained session
        } else { Issue.record("expected succeeded") }

        if case .failed(let r) = outcome(["status": AnyCodable("failed"), "reason": AnyCodable("nope")]) {
            #expect(r == "nope")
        } else { Issue.record("expected failed") }

        if case .conflict = outcome(["status": AnyCodable("conflict")]) {} else {
            Issue.record("expected conflict")
        }
        if case .unsupported = outcome(["status": AnyCodable("weird")]) {} else {
            Issue.record("expected unsupported for unknown status")
        }
        if case .unsupported = outcome(nil) {} else {
            Issue.record("expected unsupported for nil dict")
        }
    }

    @Test("Missing optional fields fall back to defaults")
    internal func invokeResultDefaults() {
        if case .needsConfirmation(let c, let p) = ArtifactActionInvokeResult
            .from(["status": AnyCodable("needs_confirmation")]).outcome {
            #expect(c.isEmpty)
            #expect(p == "Confirm action?")
        } else { Issue.record("expected needsConfirmation") }

        if case .failed(let r) = ArtifactActionInvokeResult
            .from(["status": AnyCodable("failed")]).outcome {
            #expect(r == "Action failed")
        } else { Issue.record("expected failed") }

        // succeeded without session_id → no click-through target. An empty
        // session_id is treated as absent, not as a navigable id.
        if case .succeeded(_, let sid) = ArtifactActionInvokeResult
            .from(["status": AnyCodable("succeeded")]).outcome {
            #expect(sid == nil)
        } else { Issue.record("expected succeeded") }
        if case .succeeded(_, let sid) = ArtifactActionInvokeResult
            .from(["status": AnyCodable("succeeded"), "session_id": AnyCodable("")]).outcome {
            #expect(sid == nil)
        } else { Issue.record("expected succeeded") }
    }

    // MARK: - IntentInvocationState.from(ledgerOutcome:)

    @Test("Ledger outcomes map to displayable states; non-terminal ones return nil")
    internal func ledgerOutcomeMapping() {
        #expect(ArtifactStore.IntentInvocationState.from(ledgerOutcome: "succeeded", reason: nil)
                == .succeeded(message: nil, sessionID: nil))
        #expect(ArtifactStore.IntentInvocationState.from(ledgerOutcome: "failed", reason: "boom")
                == .failed(reason: "boom"))
        #expect(ArtifactStore.IntentInvocationState.from(ledgerOutcome: "failed", reason: nil)
                == .failed(reason: "Unknown error"))
        #expect(ArtifactStore.IntentInvocationState.from(ledgerOutcome: "conflict", reason: nil)
                == .conflict)
        #expect(ArtifactStore.IntentInvocationState.from(ledgerOutcome: "unsupported", reason: nil)
                == .unsupported)
        // Non-terminal / unknown outcomes are not re-displayed.
        #expect(ArtifactStore.IntentInvocationState.from(ledgerOutcome: "needs_confirmation", reason: nil) == nil)
        #expect(ArtifactStore.IntentInvocationState.from(ledgerOutcome: "running", reason: nil) == nil)
    }

    // MARK: - LivingArtifact.from — gateway record decode + actions flattening

    @Test("Artifact record decodes with defaults and flattens the actions manifest")
    internal func livingArtifactFromRecord() throws {
        let record: [String: AnyCodable] = [
            "id": AnyCodable("issues"),
            "kind": AnyCodable("html"),
            "title": AnyCodable("Issues"),
            "content": AnyCodable("<html></html>"),
            "rev": AnyCodable(9),
            "actions": .array([
                .dictionary([
                    "type": AnyCodable("intent"),
                    "id": AnyCodable("archive"),
                    "label": AnyCodable("Archive"),
                    "presentation": .dictionary(["role": AnyCodable("destructive")]),
                ]),
                .dictionary([
                    "type": AnyCodable("choice"),
                    "field": AnyCodable("status"),
                    "options": .array([AnyCodable("open"), AnyCodable("closed")]),
                ]),
            ]),
        ]
        let artifact = try #require(LivingArtifact.from(record))
        #expect(artifact.id == "issues")
        #expect(artifact.kind == "html")
        #expect(artifact.rev == 9)
        #expect(artifact.topLevelActions.count == 2)

        let intent = try #require(artifact.topLevelActions.first { $0.kind == .intent })
        #expect(intent.bindingID == "archive")
        #expect(intent.presentationRole == .destructive)   // nested role survived flattening

        let choice = try #require(artifact.topLevelActions.first { $0.kind == .choice })
        #expect(choice.field == "status")
        #expect(choice.options == ["open", "closed"])       // string array survived flattening
    }

    @Test("Record without id is rejected; kind/rev default when absent")
    internal func livingArtifactDefaults() throws {
        #expect(LivingArtifact.from(["kind": AnyCodable("html")]) == nil)
        #expect(LivingArtifact.from(nil) == nil)

        let minimal = try #require(LivingArtifact.from(["id": AnyCodable("x")]))
        #expect(minimal.kind == "markdown")   // default kind
        #expect(minimal.rev == 0)             // default rev
        #expect(minimal.topLevelActions.isEmpty)
    }

    // MARK: - HTMLArtifactIntentRequest — entity_ref caps

    @Test("entity_ref over 512 bytes is rejected")
    internal func entityRefByteCap() throws {
        let big = String(repeating: "a", count: 513)
        let url = try #require(URL(string:
            "hermes-artifact-action://invoke?binding_id=ok&entity_ref=\(big)&nonce=n"))
        #expect(HTMLArtifactIntentRequest(url: url, expectedNonce: "n") == nil)

        let atCap = String(repeating: "a", count: 512)
        let okURL = try #require(URL(string:
            "hermes-artifact-action://invoke?binding_id=ok&entity_ref=\(atCap)&nonce=n"))
        #expect(HTMLArtifactIntentRequest(url: okURL, expectedNonce: "n") != nil)
    }

    @Test("entity_ref containing a control character is rejected")
    internal func entityRefControlChar() throws {
        // %01 = SOH control character.
        let url = try #require(URL(string:
            "hermes-artifact-action://invoke?binding_id=ok&entity_ref=a%01b&nonce=n"))
        #expect(HTMLArtifactIntentRequest(url: url, expectedNonce: "n") == nil)
    }
}
