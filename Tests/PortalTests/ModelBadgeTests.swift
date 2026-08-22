import Combine
import Testing
import Foundation
@testable import Portal

/// Regression coverage for "it just says No model after the first turn."
///
/// The user's report, verbatim shape: a session runs a turn with a model shown
/// in the top-left badge; they send another turn on the SAME session; the
/// badge flips to "No model" — while the backend routes the turn to a model
/// perfectly well.
///
/// The mechanism: `session.info` fires for many reasons (usage updates at turn
/// boundaries, workspace moves, the connect announcement), and a session whose
/// model is ROUTED per-turn reports `model: ""` — the field means "no pinned
/// override", not "no model". The desktop adopted it unconditionally, so the
/// first model-less info event after a turn wiped a badge that was correct a
/// moment earlier. The harness's own `_session_info` documents the identical
/// trap for `reasoning_effort` ("Reporting '' here made the desktop adopt the
/// empty value after the first turn").
@Suite("Model badge")
@MainActor
internal struct ModelBadgeTests {

    private func sessionInfo(model: String) -> GatewayEvent {
        .sessionInfo(SessionInfo(
            model: model,
            reasoningEffort: "",
            fast: false,
            tools: [:],
            skills: [:],
            cwd: "",
            version: "",
            usage: nil,
            mcpServers: nil
        ))
    }

    @Test("a model-less session.info does not wipe a known model")
    internal func emptyModelDoesNotWipeTheBadge() {
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        #expect(vm.currentModel == "claude-opus-5")

        // The next turn's usage-bearing info event on a routed session names
        // no model. The badge must keep saying what it knows.
        vm.receiveGatewayEventForTesting(sessionInfo(model: ""), sessionID: sid)
        #expect(vm.currentModel == "claude-opus-5")
    }

    @Test("a session.info that names a different model still updates")
    internal func namedModelStillUpdates() {
        // The guard must only reject silence, not change — or a real
        // server-side switch would never reach the badge.
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-sonnet-5"), sessionID: sid)
        #expect(vm.currentModel == "claude-sonnet-5")
    }

    @Test("the session-less connect announcement also refuses an empty model")
    internal func globalAnnouncementRefusesEmptyModel() {
        // The gateway's on-connect default announcement routes through the
        // global handler, not applySessionEvent — it has the same trap.
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        vm.receiveGatewayEventForTesting(sessionInfo(model: ""), sessionID: nil)
        #expect(vm.currentModel == "claude-opus-5")
    }

    @Test("the empty guard does not block the badge's first fill")
    internal func firstNamedModelFillsTheBadge() {
        // Starting empty and receiving a named model is the normal cold path —
        // the guard must not make "No model" sticky.
        let vm = ChatViewModel()
        let sid = "model-badge-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)
        #expect(vm.currentModel.isEmpty)

        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        #expect(vm.currentModel == "claude-opus-5")
    }
}

// MARK: - Badge across session switches

/// Backend stub whose `model.options` answers PER SESSION, the way the gateway
/// does, plus a `session.resume` that returns history. Both are needed to
/// reproduce "No model" on every session but the first.
@MainActor
private final class ModelBadgeBackendSpy: AgentBackend {
    internal let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()
    internal let connectionStatePublisher = Just(GatewayClient.ConnectionState.connected).eraseToAnyPublisher()
    internal let sessionInfoPublisher = Just<SessionInfo?>(nil).eraseToAnyPublisher()
    internal var connectionState: GatewayClient.ConnectionState = .connected
    internal var onReconnected: (() async -> Void)?
    internal let apiKey = ""
    internal var activeSessionID: String?
    internal let capabilities = BackendCapabilities.hermes

    /// Catalog the gateway answers with, keyed by the session asked about.
    internal var catalogBySession: [String: ModelCatalog] = [:]
    /// History `session.resume` returns, keyed by resume key.
    internal var historyBySession: [String: [[String: AnyCodable]]] = [:]
    /// Runtime (short hex) ID `session.resume` binds, keyed by resume key.
    internal var runtimeIDBySession: [String: String] = [:]
    private(set) var modelOptionsCalls: [String?] = []

    internal func modelOptions(sessionID: String?, refresh: Bool) async throws -> ModelCatalog? {
        modelOptionsCalls.append(sessionID)
        guard let sessionID else { return nil }
        return catalogBySession[sessionID]
    }

    internal func createSession(cols: Int) async throws -> String { "spy-session" }
    internal func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) {
        let runtimeID = runtimeIDBySession[key] ?? key
        activeSessionID = runtimeID
        return (runtimeID, historyBySession[key] ?? [])
    }
    internal func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] { [] }
    internal func interrupt(sessionID: String) async throws {}
    internal func submitPrompt(sessionID: String, text: String) async throws {}
    internal func respondApproval(sessionID: String, choice: String, all: Bool) async throws {}
    internal func respondClarify(requestID: String, answer: String) async throws {}
    internal func setConfig(key: String, value: String, sessionID: String?) async throws {}
    internal func setEphemeralPrompt(sessionID: String, prompt: String) async throws {}
    internal func setSessionSkills(sessionID: String, skillNames: [String]) async throws {}
    internal func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String?) async throws -> String {
        filename
    }
    internal func downloadFile(from url: URL, token: String?) async throws -> Data { Data() }
    internal func attachImage(path: String, sessionID: String?) async throws {}
    internal func voiceToggle(action: String) async throws -> [String: AnyCodable]? { [:] }
    internal func voiceRecord(action: String) async throws {}
    internal func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {}
}

/// Regression coverage for the second half of the same report: "for BOTH of
/// them it says no model right now", with two live sessions being clicked
/// between.
///
/// Three separate causes stacked up here:
///  1. `session.resume` rebuilt the session's runtime state from scratch, so
///     every switch wiped the badge (and the session's skills/response style).
///  2. `model.options` was cached once per launch, and the early return skipped
///     the badge fill — so any session after the first stayed blank forever.
///  3. Nothing asked the gateway what model a newly-selected session was on;
///     only the picker view did, once, whenever it first appeared.
@Suite("Model badge across session switches")
@MainActor
internal struct ModelBadgeSessionSwitchTests {

    private func sessionInfo(model: String) -> GatewayEvent {
        .sessionInfo(SessionInfo(
            model: model,
            reasoningEffort: "",
            fast: false,
            tools: [:],
            skills: [:],
            cwd: "",
            version: "",
            usage: nil,
            mcpServers: nil
        ))
    }

    private func catalog(currentModel: String) -> ModelCatalog {
        ModelCatalog(
            providers: [
                ModelCatalog.Provider(
                    slug: "anthropic",
                    name: "Anthropic",
                    models: ["claude-opus-5", "claude-sonnet-5"],
                    authenticated: true,
                    isCurrent: true
                )
            ],
            currentModel: currentModel,
            currentProvider: "anthropic"
        )
    }

    /// Spin the runloop until the badge fills (the fill is a detached Task off
    /// the session switch) or we give up.
    private func awaitBadge(_ vm: ChatViewModel) async {
        for _ in 0..<200 where vm.currentModel.isEmpty {
            await Task.yield()
        }
    }

    @Test("a session.resume does not wipe the session's model")
    internal func resumeKeepsTheBadge() async {
        let backend = ModelBadgeBackendSpy()
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)
        let sid = "badge-resume-\(UUID().uuidString)"
        backend.runtimeIDBySession[sid] = "rt-\(UUID().uuidString)"
        backend.historyBySession[sid] = [
            ["role": AnyCodable("user"), "text": AnyCodable("hi")],
            ["role": AnyCodable("assistant"), "text": AnyCodable("hello")]
        ]

        _ = vm.beginSwitchToSession(key: sid)
        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sid)
        #expect(vm.currentModel == "claude-opus-5")

        let resumed = await vm.resumeSession(key: sid)
        #expect(resumed)
        #expect(vm.messages.count == 2)
        // The transcript is what a resume refreshes — not the session's identity.
        #expect(vm.currentModel == "claude-opus-5")
    }

    @Test("a routed session fills its badge from model.options")
    internal func routedSessionFillsFromCatalog() async {
        let backend = ModelBadgeBackendSpy()
        let sid = "badge-routed-\(UUID().uuidString)"
        backend.catalogBySession[sid] = catalog(currentModel: "claude-opus-5")
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)

        _ = vm.beginSwitchToSession(key: sid)
        // A session whose model is routed per turn reports NO model over
        // session.info — model.options is the only place to learn it.
        vm.receiveGatewayEventForTesting(sessionInfo(model: ""), sessionID: sid)
        await awaitBadge(vm)

        #expect(vm.currentModel == "claude-opus-5")
    }

    @Test("the second session gets its own model, not a blank badge")
    internal func secondSessionAlsoFillsItsBadge() async {
        let backend = ModelBadgeBackendSpy()
        let suffix = UUID().uuidString
        let sessionA = "badge-a-\(suffix)"
        let sessionB = "badge-b-\(suffix)"
        backend.catalogBySession[sessionA] = catalog(currentModel: "claude-opus-5")
        backend.catalogBySession[sessionB] = catalog(currentModel: "claude-sonnet-5")
        let vm = ChatViewModel()
        vm.setGatewayClient(backend)

        _ = vm.beginSwitchToSession(key: sessionA)
        await awaitBadge(vm)
        #expect(vm.currentModel == "claude-opus-5")

        // The launch-wide catalog cache used to short-circuit here, leaving
        // "No model" on screen for every session but the first.
        _ = vm.beginSwitchToSession(key: sessionB)
        await awaitBadge(vm)
        #expect(vm.currentModel == "claude-sonnet-5")

        // Back to A: its own cached state answers, no refetch needed.
        _ = vm.beginSwitchToSession(key: sessionA)
        #expect(vm.currentModel == "claude-opus-5")
    }

    @Test("an uncached session does not inherit the previous session's model")
    internal func uncachedSessionDoesNotInheritTheBadge() {
        // No client wired: the badge fill is a no-op, so this isolates what the
        // switch itself leaves on screen.
        let vm = ChatViewModel()
        let suffix = UUID().uuidString
        let sessionA = "badge-keep-\(suffix)"
        let sessionB = "badge-fresh-\(suffix)"

        _ = vm.beginSwitchToSession(key: sessionA)
        vm.receiveGatewayEventForTesting(sessionInfo(model: "claude-opus-5"), sessionID: sessionA)
        #expect(vm.currentModel == "claude-opus-5")

        _ = vm.beginSwitchToSession(key: sessionB)
        #expect(vm.currentModel.isEmpty)

        _ = vm.beginSwitchToSession(key: sessionA)
        #expect(vm.currentModel == "claude-opus-5")
    }
}
