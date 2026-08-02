import Foundation
import Testing
#if os(macOS)
import WebKit
#endif
@testable import Portal

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

    @Test("Pointer Lock bridge accepts only trusted gestures")
    internal func pointerLockBridgeIsGestureScoped() {
        let js = HTMLPointerLockBridge.userScriptSource
        #expect(js.contains("pointerdown"))
        #expect(js.contains("event.isTrusted"))
        #expect(js.contains("closest('canvas')"))
        #expect(js.contains("document.pointerLockElement"))
        #expect(js.contains("canvas.requestPointerLock()"))
        #expect(!js.contains("window.location"))
        #expect(!js.contains("fetch("))
    }

    @Test("Pointer Lock bridge captures through HUD overlays but not through controls")
    internal func pointerLockBridgeCapturesThroughOverlays() {
        let js = HTMLPointerLockBridge.userScriptSource
        // Generated worlds cover the canvas with HUD elements; a click there
        // must still reach the dominant canvas...
        #expect(js.contains("dominantCanvas"))
        // ...but never when the click is operating a real control,
        #expect(js.contains("[role=\"button\"]"))
        #expect(js.contains("contenteditable"))
        // ...and never for small canvases (a chart in a report), which is the
        // viewport-fraction gate.
        let fraction = HTMLPointerLockBridge.immersiveCanvasViewportFraction
        #expect(fraction > 0 && fraction < 1)
        #expect(js.contains("\(fraction)"))
    }

    #if os(macOS)
    /// The bug this guards: WebKit asks the `uiDelegate` for permission via
    /// `WKUIDelegatePrivate` selectors and denies the lock when nobody answers.
    /// A typo in an `@objc` name is invisible at compile time and looks exactly
    /// like the original "cursor never captures" symptom, so assert the runtime
    /// actually exposes the names WebKit probes.
    @MainActor
    @Test("Pointer Lock delegate answers the selectors WebKit probes for permission")
    internal func pointerLockDelegateAnswersWebKitProbes() {
        let delegate = ArtifactPointerLockDelegate()
        for name in [
            ArtifactPointerLockDelegate.requestSelectorName,
            ArtifactPointerLockDelegate.legacyRequestSelectorName,
            ArtifactPointerLockDelegate.didLoseSelectorName
        ] {
            #expect(
                delegate.responds(to: NSSelectorFromString(name)),
                "WebKit probes \(name); an unanswered selector silently denies Pointer Lock"
            )
        }
        // Names are load-bearing (WebKit looks them up as strings), so pin them.
        #expect(ArtifactPointerLockDelegate.requestSelectorName
            == "_webViewDidRequestPointerLock:completionHandler:")
        #expect(ArtifactPointerLockDelegate.legacyRequestSelectorName == "_webViewRequestPointerLock:")
        #expect(ArtifactPointerLockDelegate.didLoseSelectorName == "_webViewDidLosePointerLock:")
    }

    @MainActor
    @Test("Granting a lock request flips locked state, and losing it flips back")
    internal func pointerLockStateTracksGrantAndLoss() {
        let delegate = ArtifactPointerLockDelegate()
        #expect(delegate.isPointerLocked == false)

        var observed: [Bool] = []
        delegate.onLockChange = { observed.append($0) }

        let webView = WKWebView(frame: .zero)
        // Collected rather than a lone flag so "never called" and "called with
        // false" stay distinguishable.
        var grants: [Bool] = []
        delegate.webViewDidRequestPointerLock(webView) { grants.append($0) }
        #expect(grants == [true], "the request already cleared WebKit's own gates")
        #expect(delegate.isPointerLocked)

        delegate.webViewDidLosePointerLock(webView)
        #expect(delegate.isPointerLocked == false)
        #expect(observed == [true, false], "each transition reports exactly once")

        // reset() must clear a stale lock, or Escape would be swallowed forever.
        delegate.webViewDidRequestPointerLock(webView) { _ in }
        delegate.reset()
        #expect(delegate.isPointerLocked == false)
    }

    /// OrbitControls drags on absolute cursor position; capturing the pointer
    /// hides the cursor and starves those events, breaking a working scene.
    @Test("Auto pointer capture is scoped to html, not orbit-driven model3d")
    internal func autoPointerCaptureIsKindScoped() {
        let firstPerson = "<canvas id=c></canvas><script>onmousemove=e=>yaw+=e.movementX</script>"
        #expect(InteractiveArtifactWeb.autoCapturesPointer(kind: "html", content: firstPerson))
        #expect(!InteractiveArtifactWeb.autoCapturesPointer(kind: "model3d", content: firstPerson))
        #expect(!InteractiveArtifactWeb.autoCapturesPointer(kind: "chart", content: firstPerson))
        // Both kinds still get the immersive window itself.
        #expect(InteractiveArtifactWeb.supportsImmersiveFullscreen("html"))
        #expect(InteractiveArtifactWeb.supportsImmersiveFullscreen("model3d"))
        #expect(!InteractiveArtifactWeb.supportsImmersiveFullscreen("dataset"))
    }

    /// The regression this pins, observed on a real generated world: an html
    /// world that turns its camera on `clientX` deltas was captured purely
    /// because its kind was "html". Pointer Lock then froze `clientX`, so every
    /// drag computed a zero delta — cursor gone, camera stuck, scene unusable.
    /// Capture must therefore ask the document, not just its kind.
    @Test("A drag-to-orbit html world is never captured — lock would freeze its clientX")
    internal func autoPointerCaptureSkipsDragDrivenWorlds() {
        let dragOrbit = """
        <canvas id="c"></canvas><script>
        let dragging=false,lastX=0;
        addEventListener('mousedown',e=>{dragging=true;lastX=e.clientX;});
        addEventListener('mousemove',e=>{if(dragging){yaw-=(e.clientX-lastX)*0.003;lastX=e.clientX;}});
        </script>
        """
        #expect(!InteractiveArtifactWeb.pageUsesPointerLock(dragOrbit))
        #expect(!InteractiveArtifactWeb.autoCapturesPointer(kind: "html", content: dragOrbit))

        // Each API a page can legitimately use to read relative motion counts.
        for api in ["movementX", "movementY", "pointerLockElement",
                    "requestPointerLock", "exitPointerLock", "PointerLockControls"] {
            #expect(
                InteractiveArtifactWeb.pageUsesPointerLock("<script>\(api)</script>"),
                "\(api) means the page is written for a captured pointer"
            )
        }
    }
    #endif

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
