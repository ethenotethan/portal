import SwiftUI
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "ArtifactIntents")

// The one place that decides how an artifact of any kind is drawn, and — for
// interactive HTML worlds — whether the host captures the mouse for it. Lifted
// out of ArtifactsPane so the six views that render artifacts share a single
// answer instead of each passing their own.

/// Render any artifact kind through the same block views chat uses.
internal struct ArtifactKindRenderer: View {
    internal let kind: String
    internal let content: String
    /// The artifact id when rendering the LIVE artifact (not a history
    /// revision) — enables declared per-entry actions on dataset/map.
    internal var actionableArtifactID: String?
    /// First-class top-level actions for this artifact (HTML kind only —
    /// structured kinds embed their actions in content). These render as
    /// trusted SwiftUI chrome above the HTML document; no JS bridge involved.
    internal var topLevelActions: [ArtifactAction] = []
    /// Forces host-assisted mouse capture off for this rendering regardless of
    /// the document — history revisions, diffs, and export previews are pictures
    /// of an artifact, not something to be driven.
    ///
    /// Capture is otherwise decided from the content itself (see
    /// `capturesPointerInput`) rather than passed in by each call site. It used
    /// to be an opt-in flag defaulting to false, and three separate live views
    /// rendered interactive worlds without setting it — so a world opened from
    /// the artifact canvas got no pointer-lock bridge at all and could only be
    /// steered by dragging, while the same world in the expanded overlay
    /// captured normally. A default that silently disables the feature is the
    /// wrong default.
    internal var suppressesPointerCapture = false

    /// Whether this rendering should install the host's mouse-capture bridge:
    /// any interactive world that isn't explicitly being shown as a static
    /// picture of itself.
    private var capturesPointerInput: Bool {
        #if os(macOS)
        guard !suppressesPointerCapture else { return false }
        return InteractiveArtifactWeb.autoCapturesPointer(kind: kind, content: content)
        #else
        return false
        #endif
    }

    /// The decision above, reachable by tests without building a view hierarchy.
    internal var capturesPointerInputForTesting: Bool { capturesPointerInput }
    /// Fires when a capturing HTML canvas takes or releases Pointer Lock, so
    /// the host can suspend its own Escape handling while the page owns it.
    internal var onPointerLockChange: ((Bool) -> Void)?

    /// Kinds whose content is an interactive viewport that manages its own
    /// scrolling and gestures (a WKWebView document, a force-directed graph
    /// explorer) — they must be given a bounded height to FILL, never sit in
    /// an outer ScrollView where the unbounded height proposal breaks them.
    internal static func kindFillsHeight(_ kind: String) -> Bool {
        kind == "html" || kind == "graph"
    }

    internal var body: some View {
        switch kind {
        case "blueprint":
            BlueprintBlockView(json: content, isStreaming: false)
        case "map":
            MapBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "chart":
            NativeChartView(json: content, isStreaming: false, interactive: true)
        case "graph":
            // Artifacts get the interactive explorer (pan/zoom/drag, click-
            // through neighbors) — chat blocks keep the static NetworkGraphView.
            GraphExplorerBlockView(json: content)
        case "stats":
            StatTilesView(json: content, isStreaming: false)
        case "dataset", "table":
            DatasetBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "checklist":
            ChecklistBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "kanban":
            KanbanBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "calendar":
            CalendarBlockView(json: content, isStreaming: false)
        case "timeline":
            TimelineBlockView(json: content, isStreaming: false)
        case "sankey":
            SankeyBlockView(json: content, isStreaming: false)
        case "model":
            ModelBlockView(json: content, isStreaming: false, actionableArtifactID: actionableArtifactID)
        case "model3d":
            Model3DBlockView(json: content, isStreaming: false)
        case "html":
            // A self-contained HTML document — content is raw HTML, not JSON.
            // Renders in the same WKWebView-backed view chat uses for "Open
            // Page" on an html fence (JS on, ephemeral store, external links
            // open in the system browser).
            // A live artifact may place inert controls anywhere in its page:
            //   data-hermes-binding="start-issue"
            //   data-hermes-entity="issues/ARC-42"
            // The WKWebView bridge emits only those opaque identifiers. Native
            // validates the binding against this artifact's declared actions;
            // the gateway validates it again against the pinned revision.
            // Historical/transcript HTML gets no callback and cannot invoke.
            if let artifactID = actionableArtifactID {
                ArtifactHTMLIntentView(
                    html: content,
                    artifactID: artifactID,
                    actions: topLevelActions,
                    capturesPointerInput: capturesPointerInput,
                    onPointerLockChange: onPointerLockChange
                )
            } else {
                InlineHTMLView(
                    html: content,
                    capturesPointerInput: capturesPointerInput,
                    onPointerLockChange: onPointerLockChange
                )
                    .frame(minHeight: 320)
            }
        default:
            MarkdownContentView(text: content, isStreaming: false)
                .equatable()
        }
    }
}

// MARK: - Inline HTML artifact intents

/// Hosts inline inert intent markers while keeping invocation, confirmation,
/// and result state in trusted SwiftUI chrome. Page code receives no gateway
/// object, credentials, message handler, or arbitrary RPC surface.
private struct ArtifactHTMLIntentView: View {
    let html: String
    let artifactID: String
    let actions: [ArtifactAction]
    let capturesPointerInput: Bool
    internal var onPointerLockChange: ((Bool) -> Void)?

    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @ObservedObject private var store = ArtifactStore.shared
    @State private var activeRequest: HTMLArtifactIntentRequest?
    @State private var showConfirmation = false
    @State private var pendingChallenge = ""
    @State private var pendingPrompt = ""

    private var hasInlineBindings: Bool {
        html.contains("data-hermes-binding")
    }

    private var activeState: ArtifactStore.IntentInvocationState? {
        guard let activeRequest else { return nil }
        let slot = store.intentSlotKey(
            artifactID: artifactID,
            bindingID: activeRequest.bindingID,
            entryKey: activeRequest.entityRef
        )
        return store.intentStates[slot]
    }

    private var activeAction: ArtifactAction? {
        guard let activeRequest else { return nil }
        return HTMLArtifactIntentBridge.resolve(activeRequest, actions: actions)
    }

    /// Every live intent slot for this artifact projected to a page mark, so
    /// each inert control reflects its own status (`data-hermes-status`)
    /// independently — not just the one the user last clicked.
    private var statusMarks: [HTMLArtifactIntentBridge.StatusMark] {
        store.intentSlots(artifactID: artifactID).map { slot in
            HTMLArtifactIntentBridge.StatusMark(
                bindingID: slot.bindingID,
                entityRef: slot.entryKey,
                status: HTMLArtifactIntentBridge.StatusToken(slot.state)
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Backward-compatible fallback for existing HTML artifacts that
            // declare actions but have not placed inline markers yet.
            if !hasInlineBindings, !actions.isEmpty {
                ArtifactTopLevelActionBar(actions: actions, artifactID: artifactID)
            }
            if let activeState {
                inlineStatus(activeState)
            }
            InlineHTMLView(
                html: html,
                onArtifactIntent: handleRequest,
                statusMarks: statusMarks,
                capturesPointerInput: capturesPointerInput,
                onPointerLockChange: onPointerLockChange
            )
                .frame(minHeight: 320)
        }
        .confirmationDialog(
            activeAction?.label ?? "Confirm action",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                activeAction?.presentationRole == .destructive ? "Confirm" : (activeAction?.label ?? "Confirm"),
                role: activeAction?.presentationRole == .destructive ? .destructive : nil
            ) {
                guard let request = activeRequest else { return }
                Task {
                    await store.confirmIntent(
                        artifactID: artifactID,
                        bindingID: request.bindingID,
                        entryKey: request.entityRef,
                        challenge: pendingChallenge
                    )
                }
            }
            Button("Cancel", role: .cancel) { clearActiveState() }
        } message: {
            // Gateway-resolved, trusted prompt — never page-authored copy.
            Text(pendingPrompt)
        }
    }

    private func handleRequest(_ request: HTMLArtifactIntentRequest) {
        // Both refusals below are correct, and both used to be invisible: the
        // page has already swallowed the click by then, so a world with a dead
        // control looked identical to a world whose author forgot the markup.
        // Say which gate closed — it's the difference between "your gateway is
        // too old", "the artifact declares no such intent", and a host bug.
        guard capabilitiesStore.capabilities.supportsArtifactActions else {
            log.notice("""
            artifact intent dropped: gateway advertises no artifact.action surface \
            (binding \(request.bindingID, privacy: .public), artifact \(artifactID, privacy: .public))
            """)
            return
        }
        guard HTMLArtifactIntentBridge.resolve(request, actions: actions) != nil else {
            log.notice("""
            artifact intent dropped: binding \(request.bindingID, privacy: .public) matches no declared \
            intent on artifact \(artifactID, privacy: .public) \
            (\(actions.count, privacy: .public) action(s) declared, \
            \(actions.filter { $0.kind == .intent }.count, privacy: .public) of them intents)
            """)
            return
        }
        if case .pending = activeState { return }
        if case .needsConfirmation = activeState { return }
        activeRequest = request
        Task {
            await store.invokeIntent(
                artifactID: artifactID,
                bindingID: request.bindingID,
                entryKey: request.entityRef
            )
            let slot = store.intentSlotKey(
                artifactID: artifactID,
                bindingID: request.bindingID,
                entryKey: request.entityRef
            )
            if activeRequest == request,
               case .needsConfirmation(let challenge, let prompt) = store.intentStates[slot] {
                pendingChallenge = challenge
                pendingPrompt = prompt
                showConfirmation = true
            }
        }
    }

    @ViewBuilder
    private func inlineStatus(_ state: ArtifactStore.IntentInvocationState) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .pending:
                ProgressView().scaleEffect(0.7)
                Text("Running intent…")
            case .needsConfirmation:
                Image(systemName: "checkmark.shield")
                Text("Waiting for confirmation")
            case .succeeded(let message, let sessionID):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                if let sessionID {
                    // The gateway ran this intent as a contained session —
                    // offer click-through into the live run. Navigation goes
                    // through the same in-process notification the sidebar and
                    // inbox use, so no gateway object is threaded into the page.
                    Button {
                        ArtifactIntentSessionLink.open(sessionID: sessionID)
                    } label: {
                        HStack(spacing: 4) {
                            Text(message ?? "Started run")
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                } else {
                    Text(message ?? "Intent succeeded")
                }
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(reason)
            case .conflict:
                Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(Theme.warning)
                Text("Artifact changed. Refreshed — try again.")
            case .unsupported(let reason):
                Image(systemName: "slash.circle").foregroundStyle(Theme.tertiary)
                // Name the actual gate. "Not available on the connected harness"
                // was the same sentence whether the request reached the gateway
                // or was never sent, which sent people auditing a server that
                // had never been asked.
                Text(reason ?? "This intent is not available on the connected harness.")
            }
            Spacer()
            Button(action: clearActiveState) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border.opacity(0.5)) }
    }

    private func clearActiveState() {
        if let activeRequest {
            store.clearIntentState(
                artifactID: artifactID,
                bindingID: activeRequest.bindingID,
                entryKey: activeRequest.entityRef
            )
        }
        activeRequest = nil
        pendingChallenge = ""
        pendingPrompt = ""
        showConfirmation = false
    }
}
