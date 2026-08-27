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

    /// The bug this pins: a world whose page requested the lock from its own
    /// `click` handler captured fine, while an otherwise identical world relying
    /// on this bridge did not — because the bridge asked only on `pointerdown`,
    /// and WebKit does not honour every stage of a gesture equally. Offering the
    /// request at each stage is what makes the two behave the same.
    @Test("Pointer Lock bridge requests across the whole gesture, not just pointerdown")
    internal func pointerLockBridgeRetriesAcrossGestureStages() {
        let js = HTMLPointerLockBridge.userScriptSource
        for stage in ["pointerdown", "mouseup", "click"] {
            #expect(js.contains("'\(stage)'"), "\(stage) is a chance to be granted the lock")
        }
        // Re-entry must be free, or a granted lock would be re-requested twice
        // more in the same gesture.
        #expect(js.contains("if (!event.isTrusted || document.pointerLockElement) return"))
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
        #expect(ArtifactPointerLockDelegate.didLoseSelectorName == "_webViewDidLosePointerLock:")

        // The absence is the fix, so it needs a test more than the presence does.
        //
        // WebKit probes the older no-completion-handler shape first and, finding
        // it, never calls the modern callback. That path grants nothing today —
        // the request is refused and reaches the page as "WrongDocumentError:
        // Pointer lock requires the window to have focus", which reads like a
        // focus bug and isn't one. Re-adding this method in a well-meaning
        // "support older WebKit" change would silently break capture again, and
        // the symptom would point somewhere else entirely.
        #expect(
            !delegate.responds(to: NSSelectorFromString(
                ArtifactPointerLockDelegate.shadowingLegacySelectorName)),
            "implementing the legacy request selector shadows the modern grant, so WebKit refuses every lock"
        )
        #expect(ArtifactPointerLockDelegate.shadowingLegacySelectorName == "_webViewRequestPointerLock:")
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

    /// A pre-contract world that turns on `clientX` deltas still has to become
    /// navigable without holding a button — that was the actual complaint. It
    /// cannot be captured naively (Pointer Lock freezes `clientX`, so each drag
    /// computes a zero delta and the camera stalls), and it cannot be left
    /// uncaptured either. So it is captured *and* shimmed.
    @Test("A drag-to-look world is captured with the shim, not skipped")
    internal func dragDrivenWorldIsCapturedWithShim() {
        let dragOrbit = """
        <canvas id="c"></canvas><script>
        let dragging=false,lastX=0;
        addEventListener('mousedown',e=>{dragging=true;lastX=e.clientX;});
        addEventListener('mousemove',e=>{if(dragging){yaw-=(e.clientX-lastX)*0.003;lastX=e.clientX;}});
        </script>
        """
        #expect(!InteractiveArtifactWeb.pageUsesPointerLock(dragOrbit))
        #expect(InteractiveArtifactWeb.pageDragsToLook(dragOrbit))
        #expect(InteractiveArtifactWeb.autoCapturesPointer(kind: "html", content: dragOrbit))

        // Each API a page can legitimately use to read relative motion counts,
        // and any one of them means the page needs no translation.
        for api in ["movementX", "movementY", "pointerLockElement",
                    "requestPointerLock", "exitPointerLock", "PointerLockControls"] {
            let source = "<script>\(api); onmousedown=e=>e.clientX</script>"
            #expect(
                InteractiveArtifactWeb.pageUsesPointerLock(source),
                "\(api) means the page is written for a captured pointer"
            )
            #expect(
                !InteractiveArtifactWeb.pageDragsToLook(source),
                "\(api) means the page reads motion itself — shimming would double-drive it"
            )
        }

        // A static document with neither trait is left completely alone.
        let inert = "<h1>report</h1><canvas id=chart></canvas>"
        #expect(!InteractiveArtifactWeb.autoCapturesPointer(kind: "html", content: inert))
        #expect(!InteractiveArtifactWeb.pageDragsToLook(inert))
        // Kind still dominates: model3d's OrbitControls needs a real cursor.
        #expect(!InteractiveArtifactWeb.autoCapturesPointer(kind: "model3d", content: dragOrbit))
    }

    /// The bug this pins: capture used to be an opt-in flag on the renderer that
    /// defaulted to false, and the artifact canvas — the view you land in when you
    /// click an artifact open — never set it. So the same world captured the mouse
    /// in the expanded overlay and could only be dragged in the canvas. Nothing
    /// about a call site says whether a document is a world; the document does.
    /// Assert a renderer constructed with no capture argument at all still
    /// captures, and that a static presentation can still opt out.
    @MainActor
    @Test("Capture is derived from the document, not opted into per call site")
    internal func rendererDerivesCaptureFromContent() {
        let world = """
        <canvas id="c"></canvas><script>
        addEventListener('mousedown',e=>{dragging=true;lastX=e.clientX;});
        addEventListener('mousemove',e=>{if(dragging){yaw-=(e.clientX-lastX);lastX=e.clientX;}});
        </script>
        """
        // No `suppressesPointerCapture:` — the default must not disable the feature.
        #expect(ArtifactKindRenderer(kind: "html", content: world).capturesPointerInputForTesting)
        // A revision preview / export is a picture of the artifact, not a world
        // to drive, and stays inert even though the content is identical.
        #expect(!ArtifactKindRenderer(
            kind: "html", content: world, suppressesPointerCapture: true
        ).capturesPointerInputForTesting)
        // Kind still dominates, and an inert document is never captured.
        #expect(!ArtifactKindRenderer(kind: "model3d", content: world).capturesPointerInputForTesting)
        #expect(!ArtifactKindRenderer(kind: "html", content: "<h1>report</h1>").capturesPointerInputForTesting)
    }

    /// The shim replaces the trusted `mousemove` rather than adding to it. If the
    /// frozen `clientX` pair reached the page it would compute a delta that
    /// exactly cancels the synthetic one, and the camera would sit still — the
    /// same symptom as no shim at all.
    @Test("Drag-look shim suppresses frozen coordinates and synthesizes a held drag")
    internal func dragLookShimTranslatesCapturedMotion() {
        let js = HTMLPointerLockBridge.dragLookShimSource
        // Only acts while the lock is held, and only on real device motion.
        #expect(js.contains("document.pointerLockElement"))
        #expect(js.contains("event.isTrusted"))
        // Drives the page off relative motion...
        #expect(js.contains("event.movementX"))
        #expect(js.contains("event.movementY"))
        // ...as a button-held drag, which is what such pages require.
        #expect(js.contains("mousedown"))
        #expect(js.contains("mousemove"))
        #expect(js.contains("mouseup"))
        // The frozen pair must never reach the page.
        #expect(js.contains("stopImmediatePropagation"))
        // Releasing the lock must end the synthetic drag, or the page stays
        // stuck believing a button is still down.
        #expect(js.contains("pointerlockchange"))
        // Never a native surface.
        #expect(!js.contains("webkit.messageHandlers"))
        #expect(!js.contains("fetch("))
    }
    #endif

    // MARK: - ArtifactStore.intentSlots — decode composite keys

    @MainActor
    @Test("intentSlots decodes binding + entity back out of the composite slot key")
    internal func intentSlotsDecode() throws {
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
        let match = try #require(slots.first)
        #expect(match.bindingID == "archive")
        #expect(match.entryKey == "issues/ARC-42")
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

    // Both of these use `confirmation` rather than a captured `var` the observer
    // block increments. `addObserver`'s block is `@Sendable`, so mutating a local
    // from inside it is a data race the compiler is right to flag — it happens to
    // be safe here only because `queue: nil` delivers synchronously on the
    // posting thread, which is not something the signature promises.
    // `Confirmation` is Sendable and exists for exactly this assertion shape:
    // "this callback must fire (this many times)".

    @Test("A blank session id yields no notification and posts nothing")
    internal func sessionLinkBlankIsNoop() async {
        #expect(ArtifactIntentSessionLink.switchNotification(sessionID: "   ") == nil)

        let center = NotificationCenter()
        await confirmation("switch posted", expectedCount: 0) { posted in
            let token = center.addObserver(
                forName: .hermesSwitchToSession, object: nil, queue: nil) { _ in posted() }
            defer { center.removeObserver(token) }
            ArtifactIntentSessionLink.open(sessionID: "", center: center)
        }
    }

    @Test("open posts a switch carrying the session id")
    internal func sessionLinkOpenPosts() async {
        let center = NotificationCenter()
        await confirmation("switch posted") { posted in
            let token = center.addObserver(
                forName: .hermesSwitchToSession, object: nil, queue: nil) { note in
                #expect(note.userInfo?["session_id"] as? String == "sess-xyz")
                posted()
            }
            defer { center.removeObserver(token) }
            ArtifactIntentSessionLink.open(sessionID: "sess-xyz", center: center)
        }
    }
}
