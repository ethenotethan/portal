import Combine
import Foundation
import Testing
@testable import Portal

// MARK: - Fixtures

private func makePage(path: String = "entities/dflash-mlx.md", title: String = "DFlash MLX", contested: Bool = false) -> WikiPage {
    WikiPage(
        id: "dflash-mlx", title: title, type: "entity", tags: ["ml"], path: path, created: nil, updated: "2026-09-20",
        confidence: "high", contested: contested, tagPath: ["ml/inference/speculative-decoding"], integrationLinks: []
    )
}

private func makeNode(
    id: String = "launchd:ai.hermes.gateway", kind: String = "service", type: String = "launchd", label: String = "Hermes gateway",
    schedule: String? = nil, enabled: Bool = true, architecture: CronServiceArchitectureRef? = nil, sourceFiles: [CronSourceFile] = []
) -> CronGraphNode {
    CronGraphNode(
        id: id, kind: kind, type: type, label: label, description: "Serves the RPC.", schedule: schedule, enabled: enabled,
        usesLLM: false, lastStatus: "ok", deliver: nil, sourceFiles: sourceFiles, architecture: architecture
    )
}

/// Records the calls the dock makes; every other backend method is inert.
private final class PageIntentBackendSpy: AgentBackend, @unchecked Sendable {
    var eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()
    var connectionStatePublisher: AnyPublisher<GatewayClient.ConnectionState, Never> {
        Just(GatewayClient.ConnectionState.connected).eraseToAnyPublisher()
    }
    var sessionInfoPublisher: AnyPublisher<SessionInfo?, Never> { Just(nil).eraseToAnyPublisher() }
    var connectionState: GatewayClient.ConnectionState = .connected
    var onReconnected: (() async -> Void)?
    var apiKey: String { "test-key" }
    var activeSessionID: String? { createdSessions.last }

    private(set) var createdSessions: [String] = []
    /// Every prompt set; `pagePrompts` keeps only the dock's (ChatViewModel sets its own base prompt on create).
    private(set) var prompts: [(sessionID: String, prompt: String)] = []
    var pagePrompts: [(sessionID: String, prompt: String)] { prompts.filter { $0.prompt.contains("attached to one of its pages") } }
    private(set) var submitted: [(sessionID: String, text: String)] = []
    var failPrompt = false

    func createSession(cols: Int) async throws -> String {
        let id = "sess-\(createdSessions.count + 1)"
        createdSessions.append(id)
        return id
    }
    func resumeSession(key: String) async throws -> (sessionID: String, messages: [[String: AnyCodable]]) { (key, []) }
    func sessionHistory(sessionID: String) async throws -> [[String: AnyCodable]] { [] }
    func interrupt(sessionID: String) async throws {}
    func submitPrompt(sessionID: String, text: String) async throws { submitted.append((sessionID, text)) }
    func submitPrompt(sessionID: String, text: String, chatMode: Bool) async throws { submitted.append((sessionID, text)) }
    func respondApproval(sessionID: String, choice: String, all: Bool) async throws {}
    func respondClarify(requestID: String, answer: String) async throws {}
    func setConfig(key: String, value: String, sessionID: String?) async throws {}
    func setEphemeralPrompt(sessionID: String, prompt: String) async throws {
        if failPrompt { throw GatewayError.invalidResponse("prompt refused") }
        prompts.append((sessionID, prompt))
    }
    func setSessionSkills(sessionID: String, skillNames: [String]) async throws {}
    func uploadFile(data: Data, filename: String, mimeType: String, sessionID: String?) async throws -> String { "" }
    func downloadFile(from url: URL, token: String?) async throws -> Data { Data() }
    func attachImage(path: String, sessionID: String?) async throws {}
    func voiceToggle(action: String) async throws -> [String: AnyCodable]? { nil }
    func voiceRecord(action: String) async throws {}
    func recordDroppedEvent(_ event: GatewayEvent, sessionID: String?, reason: String) {}
}

/// A voice service that says yes, so the dock's conversation start is observable.
private final class DockVoiceFake: LocalVoiceControlling {
    var isEnabledAndAvailable = true
    var conversationMode = true
    var isRunning = false
    var onFinalTranscript: ((String) -> Void)?
    var onPartialTranscript: ((String) -> Void)?
    var onAudioLevel: ((Float) -> Void)?
    private(set) var conversationStarts = 0
    func start() async { isRunning = true }
    func startConversation() async { isRunning = true; conversationStarts += 1 }
    func stop() async { isRunning = false }
    func cancel() async { isRunning = false }
}

// MARK: - Context

@Suite("Page intent context — the page reduced to what the agent needs")
internal struct PageIntentContextTests {
    @Test("a wiki page selection names the page, its taxonomy, pins, filter and event, and asks the agent to read them")
    internal func wikiContext() {
        let context = PageIntentContext.wiki(
            name: "research", availableWikis: ["research", "ops"], selectedPage: makePage(contested: true),
            pinnedPaths: ["concepts/kv-cache.md"], searchQuery: "  mlx ", focusedEventKey: "evt-42", pageCount: 120
        )
        #expect(context.scope == .wiki(name: "research"))
        #expect(context.title == "Wiki: research")
        #expect(context.stateLines.contains("Wiki: research · 120 page(s) in the graph"))
        #expect(context.stateLines.contains("Other wikis on this gateway: ops"))
        #expect(context.stateLines.contains { $0.contains("entities/dflash-mlx.md") && $0.contains("DFlash MLX") && $0.contains("contested") })
        #expect(context.stateLines.contains("Taxonomy: ml/inference/speculative-decoding"))
        #expect(context.stateLines.contains("Pinned pages: concepts/kv-cache.md"))
        #expect(context.stateLines.contains("Search filter in effect: \"mlx\""))
        #expect(context.stateLines.contains("Focused event: evt-42"))
        #expect(context.preloadSteps.first?.contains("wiki.page") == true)
        #expect(context.preloadSteps.contains { $0.contains("wiki.scan") })
        #expect(context.preloadSteps.contains { $0.contains("concepts/kv-cache.md") })
        #expect(context.preloadSteps.contains { $0.contains("wiki.changesets") })
    }

    @Test("no page open is stated plainly; the default wiki is named; one wiki lists no others")
    internal func wikiOverview() {
        let context = PageIntentContext.wiki(
            name: nil, availableWikis: ["default"], selectedPage: nil, pinnedPaths: [], searchQuery: "", focusedEventKey: nil, pageCount: 3
        )
        #expect(context.scope == .wiki(name: "default"))
        #expect(context.stateLines.contains("No page is open; the user is looking at the whole graph."))
        #expect(!context.stateLines.contains { $0.hasPrefix("Other wikis") })
        #expect(context.preloadSteps.count == 1)
        #expect(PageIntentContext.wikiName("  ") == "default")
    }

    @Test("a selected service node with an architecture model asks for the graph, the node and architecture.describe")
    internal func cronServiceContext() {
        let ref = CronServiceArchitectureRef(ref: "arch:portal", source: "local", revision: "abc", checkStatus: "passed", snapshots: 3)
        let files = (1...7).map {
            CronSourceFile(path: "/opt/svc/f\($0).py", declared: "f\($0).py", role: "source", root: nil, relativePath: nil, exists: true)
        }
        let node = makeNode(architecture: ref, sourceFiles: files)
        let context = PageIntentContext.cronGraph(
            selectedNode: node, collapsedGroups: ["Sinks", "Resources"], showRevisions: true, nodeCount: 42, jobCount: 9
        )
        #expect(context.scope == .cronGraph)
        #expect(context.title == "Cron graph")
        #expect(context.stateLines.first == "Cron dataflow graph: 42 node(s), 9 job(s)")
        #expect(context.stateLines.contains { $0.contains("Hermes gateway [service/launchd] id launchd:ai.hermes.gateway") && $0.contains("last run ok") })
        #expect(context.stateLines.contains("Collapsed groups: Resources, Sinks"))
        #expect(context.stateLines.contains("The revisions (changeset) panel is open."))
        #expect(context.preloadSteps.first?.contains("cron.graph") == true)
        #expect(context.preloadSteps.contains { $0.contains("architecture.describe") && $0.contains("arch:portal") })
        #expect(context.preloadSteps.contains { $0.contains("/opt/svc/f6.py") && $0.contains("…") })
        #expect(context.preloadSteps.contains { $0.contains("changesets") })
    }

    @Test("a job node asks for cron.manage; a wiki resource node asks for its page; nothing selected says so")
    internal func cronJobAndWikiNodes() {
        let job = makeNode(id: "job:digest", kind: "job", type: "cron", label: "Digest", schedule: "0 7 * * *", enabled: false)
        let jobContext = PageIntentContext.cronGraph(selectedNode: job, collapsedGroups: [], showRevisions: false, nodeCount: 1, jobCount: 1)
        #expect(jobContext.stateLines.contains { $0.contains("schedule 0 7 * * *") && $0.contains("disabled") })
        #expect(jobContext.preloadSteps.contains { $0.contains("cron.manage") })
        let wiki = makeNode(id: "wiki:concepts/kv-cache", kind: "resource", type: "wiki", label: "kv-cache")
        let wikiContext = PageIntentContext.cronGraph(selectedNode: wiki, collapsedGroups: [], showRevisions: false, nodeCount: 1, jobCount: 0)
        #expect(wikiContext.preloadSteps.contains { $0.contains("concepts/kv-cache.md") })
        let empty = PageIntentContext.cronGraph(selectedNode: nil, collapsedGroups: [], showRevisions: false, nodeCount: 0, jobCount: 0)
        #expect(empty.stateLines.contains("No node is selected; the user is looking at the whole graph."))
    }

    @Test("the digest is stable for equal state and moves with any line")
    internal func digest() {
        let a = PageIntentContext.wiki(name: "r", availableWikis: [], selectedPage: makePage(), pinnedPaths: [], searchQuery: "", focusedEventKey: nil, pageCount: 1)
        let b = PageIntentContext.wiki(name: "r", availableWikis: [], selectedPage: makePage(), pinnedPaths: [], searchQuery: "", focusedEventKey: nil, pageCount: 1)
        let c = PageIntentContext.wiki(name: "r", availableWikis: [], selectedPage: makePage(), pinnedPaths: [], searchQuery: "x", focusedEventKey: nil, pageCount: 1)
        #expect(a == b)
        #expect(a.digest == b.digest)
        #expect(a.digest != c.digest)
        #expect(a.digest.count == 64)
        #expect(PageIntentScope.wiki(name: "r").id == "wiki:r")
        #expect(PageIntentScope.cronGraph.id == "cron-graph")
    }
}

// MARK: - Prompt

@Suite("Page intent prompt — what the agent is told")
internal struct PageIntentPromptTests {
    @Test("the system prompt names the page, lists the state, and fixes the write paths")
    internal func systemPrompt() {
        let context = PageIntentContext.wiki(
            name: "research", availableWikis: [], selectedPage: makePage(), pinnedPaths: [], searchQuery: "", focusedEventKey: nil, pageCount: 2
        )
        let prompt = PageIntentPrompt.system(for: context)
        #expect(prompt.contains("attached to one of its pages: Wiki: research"))
        #expect(prompt.contains("- Open page: entities/dflash-mlx.md"))
        #expect(prompt.contains("`if_match`"))
        #expect(prompt.contains("`cron.manage`"))
        #expect(prompt.contains("Speech is transcribed"))
        #expect(prompt == PageIntentPrompt.system(for: context), "deterministic")
    }

    @Test("the priming message enumerates the preload steps and asks for a one-line confirmation")
    internal func primingPrompt() {
        let context = PageIntentContext.cronGraph(selectedNode: makeNode(), collapsedGroups: [], showRevisions: false, nodeCount: 3, jobCount: 1)
        let priming = PageIntentPrompt.priming(for: context)
        #expect(priming.hasPrefix("Load the context for this page now (Cron graph):"))
        #expect(priming.contains("1. Load the cron dataflow graph (cron.graph)"))
        #expect(priming.contains("2. Describe node launchd:ai.hermes.gateway"))
        #expect(priming.hasSuffix("Then confirm in one line what you have loaded and wait for the user."))
        let bare = PageIntentContext(scope: .cronGraph, stateLines: [], preloadSteps: [])
        #expect(PageIntentPrompt.priming(for: bare).contains("Nothing specific is selected"))
    }
}

// MARK: - Dock model

@MainActor
@Suite("Page intent dock — one session per page scope")
internal struct PageIntentDockModelTests {
    private func wikiContext(_ name: String, query: String = "") -> PageIntentContext {
        PageIntentContext.wiki(name: name, availableWikis: [], selectedPage: nil, pinnedPaths: [], searchQuery: query, focusedEventKey: nil, pageCount: 1)
    }

    private func makeModel(backend: PageIntentBackendSpy, voice: DockVoiceFake) -> PageIntentDockModel {
        let model = PageIntentDockModel()
        model.configure(backend: backend)
        model.makeChat = {
            let chat = ChatViewModel()
            chat.localVoiceService = voice
            return chat
        }
        return model
    }

    @Test("open creates the session, sets the page prompt, primes once, and starts listening; reopen does not re-prime")
    internal func openPrimesOnce() async {
        let backend = PageIntentBackendSpy()
        let voice = DockVoiceFake()
        let model = makeModel(backend: backend, voice: voice)
        await model.open(context: wikiContext("research"))
        #expect(model.isOpen)
        #expect(model.activeScope == .wiki(name: "research"))
        #expect(backend.createdSessions == ["sess-1"])
        #expect(backend.pagePrompts.count == 1)
        #expect(backend.pagePrompts.first?.prompt.contains("Wiki: research") == true)
        #expect(backend.pagePrompts.first?.prompt.hasPrefix(ChatViewModel.appFormattingPrompt) == true, "the chat's base prompt is kept, the page is appended")
        #expect(backend.submitted.count == 1)
        #expect(backend.submitted.first?.text.contains("Load the context for this page now") == true)
        #expect(voice.conversationStarts == 1)
        #expect(model.activeChat?.isConversationActive == true)
        #expect(model.status == nil)
        await model.close()
        #expect(!model.isOpen)
        #expect(model.activeChat?.isConversationActive == false, "closing ends the mic")
        await model.open(context: wikiContext("research"))
        #expect(backend.createdSessions.count == 1, "the session is kept across close/open")
        #expect(backend.submitted.count == 1, "priming happens once per scope")
        #expect(backend.pagePrompts.count == 1, "an unchanged context does not re-set the prompt")
        #expect(voice.conversationStarts == 2)
    }

    @Test("a changed context re-sets the prompt without re-priming; an equal one is ignored")
    internal func contextRefresh() async {
        let backend = PageIntentBackendSpy()
        let model = makeModel(backend: backend, voice: DockVoiceFake())
        await model.open(context: wikiContext("research"))
        await model.refreshPrompt(wikiContext("research"))
        #expect(backend.pagePrompts.count == 1)
        await model.refreshPrompt(wikiContext("research", query: "mlx"))
        #expect(backend.pagePrompts.count == 2)
        #expect(backend.pagePrompts.last?.prompt.contains("Search filter in effect: \"mlx\"") == true)
        #expect(backend.submitted.count == 1)
        model.updateContext(wikiContext("research", query: "k"))
        model.updateContext(wikiContext("research", query: "kv"))
        #expect(model.context?.stateLines.contains("Search filter in effect: \"kv\"") == true)
        await model.settleContext()
        #expect(backend.pagePrompts.count == 3, "rapid updates coalesce: one prompt lands after the page settles")
        #expect(backend.pagePrompts.last?.prompt.contains("\"kv\"") == true)
        await model.settleContext()
        #expect(backend.pagePrompts.count == 3, "nothing pending, nothing sent")
    }

    @Test("switching scope keeps both sessions and ends the previous conversation")
    internal func scopeSwitch() async {
        let backend = PageIntentBackendSpy()
        let voice = DockVoiceFake()
        let model = makeModel(backend: backend, voice: voice)
        await model.open(context: wikiContext("research"))
        let research = model.activeChat
        let cron = PageIntentContext.cronGraph(selectedNode: nil, collapsedGroups: [], showRevisions: false, nodeCount: 0, jobCount: 0)
        await model.open(context: cron)
        #expect(model.activeScope == .cronGraph)
        #expect(backend.createdSessions == ["sess-1", "sess-2"])
        #expect(research?.isConversationActive == false, "one voice conversation at a time")
        #expect(model.activeChat?.isConversationActive == true)
        #expect(model.openScopes == [.cronGraph, .wiki(name: "research")])
        #expect(backend.submitted.count == 2)
    }

    @Test("without voice the dock stays in text mode and says so; without a backend it says that too")
    internal func degradedModes() async {
        let backend = PageIntentBackendSpy()
        let voice = DockVoiceFake()
        voice.isEnabledAndAvailable = false
        let model = makeModel(backend: backend, voice: voice)
        await model.open(context: wikiContext("ops"))
        #expect(model.isOpen)
        #expect(model.status == "Voice is unavailable here — type below.")
        #expect(backend.submitted.count == 1, "priming still happens")
        let unconfigured = PageIntentDockModel()
        await unconfigured.open(context: wikiContext("ops"))
        #expect(unconfigured.status?.contains("No gateway client") == true)
        #expect(unconfigured.activeChat == nil)
    }

    @Test("a refused prompt is reported, and Open in Chat hands over the active session id")
    internal func promptFailureAndOpenInChat() async {
        let backend = PageIntentBackendSpy()
        backend.failPrompt = true
        let model = makeModel(backend: backend, voice: DockVoiceFake())
        var handed: [String] = []
        model.onOpenInChat = { handed.append($0) }
        model.openInChat()
        #expect(handed.isEmpty, "nothing to open before a session exists")
        await model.open(context: wikiContext("research"))
        #expect(model.status?.contains("Could not send the page context") == true)
        model.openInChat()
        #expect(handed == ["sess-1"])
    }
}
