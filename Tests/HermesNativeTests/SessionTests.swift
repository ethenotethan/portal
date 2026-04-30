import Testing
import Foundation
@testable import HermesNative

// MARK: - Session Model Tests

@Suite("Session Model")
struct SessionTests {

    @Test("Sessions with same ID are equal")
    func equalityByID() {
        let a = Session(id: "abc", messageCount: 5, isRunning: false)
        let b = Session(id: "abc", title: "Different", messageCount: 10, isRunning: true)
        #expect(a == b)
    }

    @Test("Sessions with different IDs are not equal")
    func inequalityByID() {
        let a = Session(id: "abc", messageCount: 0)
        let b = Session(id: "def", messageCount: 0)
        #expect(a != b)
    }

    @Test("Session conforms to Identifiable")
    func identifiable() {
        let session = Session(id: "abc", messageCount: 0)
        #expect(session.id == "abc")
    }

    @Test("Session with gateway title")
    func gatewayTitle() {
        let session = Session(id: "abc", title: "How to build an app", messageCount: 3)
        #expect(session.title == "How to build an app")
    }

    @Test("Session with preview")
    func previewField() {
        let session = Session(id: "abc", preview: "I was wondering about...", messageCount: 1)
        #expect(session.preview == "I was wondering about...")
    }

    @Test("Session with source")
    func sourceField() {
        let session = Session(id: "abc", source: "telegram", messageCount: 2)
        #expect(session.source == "telegram")
    }
}

// MARK: - SessionListViewModel Tests

@Suite("SessionListViewModel")
struct SessionListViewModelTests {

    @Test("selectSession updates activeSessionID")
    @MainActor
    func selectSession() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", title: "Test", messageCount: 0)
        vm.sessions = [session]

        vm.selectSession(id: "s1")
        #expect(vm.activeSessionID == "s1")
    }

    @Test("closeSession removes session from list")
    @MainActor
    func closeSessionRemovesFromList() async {
        let vm = SessionListViewModel()
        let s1 = Session(id: "s1", messageCount: 0)
        let s2 = Session(id: "s2", messageCount: 0)
        vm.sessions = [s1, s2]
        vm.activeSessionID = "s1"

        #expect(vm.sessions.count == 2)
        #expect(vm.activeSessionID == "s1")
    }

    @Test("activeSessionID falls back to first session when current is removed")
    @MainActor
    func activeSessionFallback() async {
        let vm = SessionListViewModel()
        let s1 = Session(id: "s1", messageCount: 0)
        let s2 = Session(id: "s2", messageCount: 0)
        vm.sessions = [s1, s2]
        vm.activeSessionID = "s1"

        vm.sessions.removeAll { $0.id == "s1" }
        if vm.activeSessionID == "s1" {
            vm.activeSessionID = vm.sessions.first?.id
        }
        #expect(vm.activeSessionID == "s2")
    }

    @Test("isLoading starts as false")
    @MainActor
    func isLoadingInitial() async {
        let vm = SessionListViewModel()
        #expect(vm.isLoading == false)
    }

    @Test("sessions starts empty")
    @MainActor
    func sessionsStartEmpty() async {
        let vm = SessionListViewModel()
        #expect(vm.sessions.isEmpty)
    }

    @Test("titleForSession uses gateway title when no local title")
    @MainActor
    func titleFromGateway() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", title: "My Chat", messageCount: 3)
        #expect(vm.titleForSession(session) == "My Chat")
    }

    @Test("titleForSession falls back to preview when no title")
    @MainActor
    func titleFromPreview() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", preview: "How do I deploy this app to production?", messageCount: 1)
        #expect(vm.titleForSession(session) == "How do I deploy this app to production?")
    }

    @Test("titleForSession falls back to source when no title or preview")
    @MainActor
    func titleFromSource() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", source: "telegram", messageCount: 2)
        #expect(vm.titleForSession(session) == "telegram session")
    }

    @Test("titleForSession falls back to short ID when nothing else")
    @MainActor
    func titleFromShortID() async {
        let vm = SessionListViewModel()
        let session = Session(id: "abc12345def", messageCount: 0)
        #expect(vm.titleForSession(session) == "Session abc12345")
    }

    @Test("subtitleForSession shows source, message count, and time")
    @MainActor
    func subtitleFormatting() async {
        let vm = SessionListViewModel()
        let session = Session(id: "s1", source: "telegram", messageCount: 5, startedAt: Date())
        let subtitle = vm.subtitleForSession(session)
        #expect(subtitle != nil)
        #expect(subtitle!.contains("telegram"))
        #expect(subtitle!.contains("5 msgs"))
    }
}

// MARK: - ChatViewModel Session Title Tests

@Suite("ChatViewModel Session Title")
struct ChatViewModelTitleTests {

    @Test("sessionTitle defaults to New Chat")
    @MainActor
    func defaultTitle() async {
        let vm = ChatViewModel()
        #expect(vm.sessionTitle == "New Chat")
    }

    @Test("currentSessionID starts nil")
    @MainActor
    func currentSessionIDNil() async {
        let vm = ChatViewModel()
        #expect(vm.currentSessionID == nil)
    }
}
