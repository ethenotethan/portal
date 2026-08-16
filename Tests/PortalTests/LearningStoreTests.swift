import Combine
import Foundation
import Testing
@testable import Portal

/// Gateway-sync behavior of `LearningStore`: the runtime probe, rev-guarded
/// adoption, the granular migration push, and the optimistic progress fold
/// matching the server's rules.
@MainActor
private final class FakeLearningGateway: LearningGateway {
    let eventStream = PassthroughSubject<(GatewayEvent, String?), Never>()

    /// nil = simulate an old gateway (method-not-found).
    var supportsLearning = true

    var remoteCourses: [String: LearningCourseWire] = [:]
    var remoteDecks: [String: LearningDeckWire] = [:]

    // Call recording for migration assertions.
    var courseSetCalls: [(id: String?, title: String)] = []
    var moduleSetCalls: [(courseID: String, moduleID: String?)] = []
    var stepSetCalls: [(courseID: String, moduleID: String, stepID: String?, type: String?)] = []
    var progressRecordCalls: [(courseID: String, stepID: String, kind: String, score: Int?, at: Date?)] = []
    var reviewRecordCalls: [(deckID: String, cardID: String, quality: Int, bootstrap: Bool)] = []
    var attemptRecords: [[String: Any]] = []

    func learningCourseList() async throws -> [LearningCourseSummary]? {
        guard supportsLearning else { return nil }
        return remoteCourses.values.map {
            LearningCourseSummary(id: $0.id, title: $0.title, rev: $0.rev)
        }
    }

    func learningCourseGet(id: String) async throws -> LearningCourseWire? {
        remoteCourses[id]
    }

    func learningCourseSet(
        id: String?, title: String, summary: String, sourceSessionID: String?
    ) async throws -> (id: String, rev: Int)? {
        courseSetCalls.append((id, title))
        let storedID = id ?? "crs-minted"
        if remoteCourses[storedID] == nil {
            remoteCourses[storedID] = LearningCourseWire(
                id: storedID, title: title, summary: summary, rev: 1, modules: [], progress: [:])
        }
        return (storedID, remoteCourses[storedID]?.rev ?? 1)
    }

    /// Rebuild a stored course wire with `modules` swapped — the wire struct is
    /// immutable, and the fake must mirror pushed modules/steps or the store's
    /// adopt-after-push would install a hollow copy over the local document.
    private func withModules(_ wire: LearningCourseWire, _ modules: [[String: AnyCodable]]) -> LearningCourseWire {
        LearningCourseWire(
            id: wire.id, title: wire.title, summary: wire.summary,
            rev: wire.rev, modules: modules, progress: wire.progress)
    }

    func learningCourseDelete(id: String) async throws {
        remoteCourses.removeValue(forKey: id)
    }

    func learningModuleSet(
        courseID: String, moduleID: String?, title: String?, overview: String?, position: Int?
    ) async throws -> (id: String, rev: Int)? {
        moduleSetCalls.append((courseID, moduleID))
        let mid = moduleID ?? "m-minted"
        if let wire = remoteCourses[courseID] {
            var modules = wire.modules
            if !modules.contains(where: { $0["id"]?.stringValue == mid }) {
                modules.append([
                    "id": AnyCodable(mid),
                    "title": AnyCodable(title ?? ""),
                    "overview": AnyCodable(overview ?? ""),
                    "steps": .array([]),
                ])
            }
            remoteCourses[courseID] = withModules(wire, modules)
        }
        return (mid, 2)
    }

    func learningStepSet(
        courseID: String, moduleID: String, stepID: String?,
        title: String?, type: String?, markdown: String?,
        questions: [[String: Any]]?
    ) async throws -> (id: String, rev: Int)? {
        stepSetCalls.append((courseID, moduleID, stepID, type))
        let sid = stepID ?? "s-minted"
        if let wire = remoteCourses[courseID] {
            var modules = wire.modules
            if let idx = modules.firstIndex(where: { $0["id"]?.stringValue == moduleID }) {
                var steps = modules[idx]["steps"]?.arrayValue ?? []
                var step: [String: AnyCodable] = [
                    "id": AnyCodable(sid),
                    "type": AnyCodable(type ?? "lesson"),
                    "title": AnyCodable(title ?? ""),
                ]
                if let markdown { step["markdown"] = AnyCodable(markdown) }
                if let questions { step["questions"] = AnyCodable(any: questions) }
                steps.append(.dictionary(step))
                modules[idx]["steps"] = .array(steps)
            }
            remoteCourses[courseID] = withModules(wire, modules)
        }
        return (sid, 3)
    }

    func learningDeckList() async throws -> [LearningDeckSummary]? {
        guard supportsLearning else { return nil }
        return remoteDecks.values.map {
            LearningDeckSummary(id: $0.id, topic: $0.topic, rev: $0.rev)
        }
    }

    func learningDeckGet(id: String) async throws -> LearningDeckWire? {
        remoteDecks[id]
    }

    func learningDeckSet(id: String?, topic: String) async throws -> (id: String, rev: Int)? {
        let storedID = id ?? "dk-minted"
        if remoteDecks[storedID] == nil {
            remoteDecks[storedID] = LearningDeckWire(
                id: storedID, topic: topic, rev: 1, cards: [], srs: [:])
        }
        return (storedID, remoteDecks[storedID]?.rev ?? 1)
    }

    func learningDeckDelete(id: String) async throws {
        remoteDecks.removeValue(forKey: id)
    }

    func learningCardSet(
        deckID: String, cards: [[String: Any]]
    ) async throws -> (cardIDs: [String], rev: Int)? {
        (cards.compactMap { $0["id"] as? String }, 2)
    }

    func learningProgressRecord(
        courseID: String, stepID: String, kind: String, scorePercent: Int?, at: Date?
    ) async throws {
        progressRecordCalls.append((courseID, stepID, kind, scorePercent, at))
    }

    func learningReviewRecord(
        deckID: String, cardID: String, quality: Int,
        reviewedAt: Date, bootstrapState: [String: Any]?
    ) async throws {
        reviewRecordCalls.append((deckID, cardID, quality, bootstrapState != nil))
    }

    func learningAttemptRecord(_ attempt: [String: Any]) async throws {
        attemptRecords.append(attempt)
    }
}

@Suite("Learning Store Sync", .serialized)
@MainActor
internal struct LearningStoreTests {

    private func makeStore() -> LearningStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-tests-\(UUID().uuidString)", isDirectory: true)
        return LearningStore(curriculumDirectory: dir)
    }

    private func sampleCourse() -> Curriculum {
        Curriculum(
            title: "Sync Course", summary: "s",
            modules: [CurriculumModule(
                title: "M1", overview: "o",
                steps: [
                    CurriculumStep(title: "L1", kind: .lesson(markdown: "# One")),
                    CurriculumStep(title: "Q1", kind: .quiz(questions: [
                        QuizQuestion(q: "?", options: ["A) 1", "B) 2", "C) 3", "D) 4"],
                                     correct: "A", explanation: "")
                    ])),
                ]
            )]
        )
    }

    @Test("an old gateway (nil list) leaves the store local-only")
    internal func probeFailureStaysLocal() async {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        gateway.supportsLearning = false

        store.setClient(gateway)
        await store.pull()

        #expect(gateway.courseSetCalls.isEmpty)
        // Local operation still works.
        store.saveCourse(sampleCourse())
        #expect(store.sortedCourses.count == 1)
    }

    @Test("pull adopts a newer remote course and rev-guards an older one")
    internal func pullAdoptsByRev() async {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        gateway.remoteCourses["crs-1"] = LearningCourseWire(
            id: "crs-1", title: "Remote", summary: "", rev: 5,
            modules: [], progress: [:])

        store.injectClientForTesting(gateway)
        await store.pull()
        #expect(store.course(id: "crs-1")?.rev == 5)
        #expect(store.course(id: "crs-1")?.title == "Remote")
    }

    @Test("pull migrates a rev-0 local course up granularly, with progress replay")
    internal func pullMigratesLocalCourseGranularly() async {
        let store = makeStore()
        var course = sampleCourse()
        let lessonID = course.modules[0].steps[0].id
        course.markLessonRead(stepID: lessonID)
        store.saveCourse(course)  // no client yet — stays rev 0 local

        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)
        await store.pull()

        // Shell + 1 module + 2 steps, never a whole-course blob.
        #expect(gateway.courseSetCalls.map(\.id) == [course.id])
        #expect(gateway.moduleSetCalls.count == 1)
        #expect(gateway.stepSetCalls.count == 2)
        #expect(gateway.stepSetCalls.map(\.type) == ["lesson", "quiz"])
        // Progress replayed as a fold event.
        #expect(gateway.progressRecordCalls.count == 1)
        #expect(gateway.progressRecordCalls[0].kind == "lesson_read")
        #expect(gateway.progressRecordCalls[0].stepID == lessonID)
    }

    @Test("recordQuizAttempt folds locally and stamps `at` only on a pass")
    internal func quizAttemptStampsOnlyPasses() async throws {
        let store = makeStore()
        let course = sampleCourse()
        let quizID = course.modules[0].steps[1].id
        store.saveCourse(course)

        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)

        store.recordQuizAttempt(courseID: course.id, stepID: quizID, scorePercent: 60)
        store.recordQuizAttempt(courseID: course.id, stepID: quizID, scorePercent: 90)
        // Let the fire-and-forget record tasks land.
        try await Task.sleep(for: .milliseconds(50))

        // Local fold: best-of, both attempts counted.
        let record = try #require(store.course(id: course.id)?.progress[quizID])
        #expect(record.bestScorePercent == 90)
        #expect(record.attempts == 2)

        // Wire: the failing attempt (60 < 80) carries no completion stamp;
        // the passing one does — the server folds completed_at from stamps.
        #expect(gateway.progressRecordCalls.count == 2)
        #expect(gateway.progressRecordCalls[0].at == nil)
        #expect(gateway.progressRecordCalls[1].at != nil)
    }

    @Test("saveDeck records only the session's newly-graded cards upstream")
    internal func deckSaveDiffsGrades() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)

        let cardA = Flashcard(front: "a", back: "1", explanation: "")
        let cardB = Flashcard(front: "b", back: "2", explanation: "")
        var deck = FlashcardDeck(topic: "T", cards: [cardA, cardB])
        deck.rev = 1  // already server-side; per-review sync path
        store.saveDeck(deck)
        try await Task.sleep(for: .milliseconds(50))
        #expect(gateway.reviewRecordCalls.isEmpty, "no grades yet")

        // Grade one card.
        let baseState = try #require(deck.srsStates[cardA.id])
        deck.srsStates[cardA.id] = SRSEngine.calculate(quality: 5, state: baseState)
        store.saveDeck(deck)
        try await Task.sleep(for: .milliseconds(50))

        #expect(gateway.reviewRecordCalls.count == 1)
        #expect(gateway.reviewRecordCalls[0].cardID == cardA.id)
        #expect(gateway.reviewRecordCalls[0].quality == 5)
        #expect(!gateway.reviewRecordCalls[0].bootstrap)
    }

    @Test("a learning.changed course event refetches and adopts the newer rev")
    internal func eventDrivenRefetch() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.setClient(gateway)
        try await Task.sleep(for: .milliseconds(50))  // let setClient's pull settle

        gateway.remoteCourses["crs-evt"] = LearningCourseWire(
            id: "crs-evt", title: "Pushed by agent", summary: "", rev: 2,
            modules: [], progress: [:])
        gateway.eventStream.send((
            .learningChanged(entity: "course", id: "crs-evt", rev: 2, deleted: false), nil))
        // RunLoop.main delivery + async refetch.
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.course(id: "crs-evt")?.title == "Pushed by agent")
    }

    @Test("a deleted event drops the local copy")
    internal func deleteEventRemoves() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        // setClient (not inject) so the event subscription is live —
        // injectClientForTesting deliberately skips it, and setClient's
        // identity guard makes a later call with the same instance a no-op.
        store.setClient(gateway)
        try await Task.sleep(for: .milliseconds(50))  // let the pull settle

        store.saveCourse(sampleCourse())
        let id = store.sortedCourses[0].id
        // saveCourse now pushes and adopts asynchronously; let that land so
        // the adopt cannot resurrect the course after the delete below.
        try await Task.sleep(for: .milliseconds(150))

        gateway.eventStream.send((
            .learningChanged(entity: "course", id: id, rev: 0, deleted: true), nil))
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.course(id: id) == nil)
    }

    @Test("recordAttempt mirrors the session into the gateway attempt log")
    internal func attemptMirrorsUp() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)

        let question = QuizQuestion(q: "?", options: ["A) 1", "B) 2", "C) 3", "D) 4"],
                                    correct: "A", explanation: "")
        let session = PersistedQuizSession(
            questions: [question], topic: "T",
            selectedAnswers: [question.id: "A"], score: 1, sourceSessionID: "sess")
        store.recordAttempt(session)
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.attempts.count == 1)
        #expect(store.attempts.first?.id == session.id, "newest first")
        #expect(gateway.attemptRecords.count == 1)
        #expect(gateway.attemptRecords[0]["topic"] as? String == "T")
        #expect(gateway.attemptRecords[0]["score"] as? Int == 1)
    }

    // MARK: - Remote-change events (learning.changed → refetch/delete)

    @Test("a course change event refetches and adopts the newer remote copy")
    internal func changeEventAdoptsNewerCourse() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.setClient(gateway)  // subscribes the event stream + pulls
        try await Task.sleep(for: .milliseconds(50))

        gateway.remoteCourses["crs-e"] = LearningCourseWire(
            id: "crs-e", title: "From event", summary: "", rev: 4, modules: [], progress: [:])
        gateway.eventStream.send((.learningChanged(entity: "course", id: "crs-e", rev: 4, deleted: false), nil))
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.course(id: "crs-e")?.title == "From event")
        #expect(store.course(id: "crs-e")?.rev == 4)
    }

    @Test("a stale course event (rev not newer) does not refetch — our own echo")
    internal func changeEventRevGuards() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        gateway.remoteCourses["crs-g"] = LearningCourseWire(
            id: "crs-g", title: "v5", summary: "", rev: 5, modules: [], progress: [:])
        store.setClient(gateway)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.course(id: "crs-g")?.rev == 5)

        // Remote now claims something newer exists, but the EVENT is the echo
        // of rev 5 — the guard must not refetch (and so must not adopt v6).
        gateway.remoteCourses["crs-g"] = LearningCourseWire(
            id: "crs-g", title: "v6", summary: "", rev: 6, modules: [], progress: [:])
        gateway.eventStream.send((.learningChanged(entity: "course", id: "crs-g", rev: 5, deleted: false), nil))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.course(id: "crs-g")?.title == "v5")
    }

    @Test("a deleted-course event removes the local copy; deck events mirror both")
    internal func changeEventDeletesAndDecks() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        gateway.remoteCourses["crs-d"] = LearningCourseWire(
            id: "crs-d", title: "Doomed", summary: "", rev: 1, modules: [], progress: [:])
        gateway.remoteDecks["dk-d"] = LearningDeckWire(
            id: "dk-d", topic: "Decks", rev: 1, cards: [], srs: [:])
        store.setClient(gateway)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.course(id: "crs-d") != nil)
        #expect(store.decks["dk-d"] != nil)

        gateway.eventStream.send((.learningChanged(entity: "course", id: "crs-d", rev: 2, deleted: true), nil))
        gateway.remoteDecks["dk-d"] = LearningDeckWire(
            id: "dk-d", topic: "Fresh topic", rev: 3, cards: [], srs: [:])
        gateway.eventStream.send((.learningChanged(entity: "deck", id: "dk-d", rev: 3, deleted: false), nil))
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.course(id: "crs-d") == nil)
        #expect(store.decks["dk-d"]?.topic == "Fresh topic")

        gateway.eventStream.send((.learningChanged(entity: "deck", id: "dk-d", rev: 4, deleted: true), nil))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.decks["dk-d"] == nil)
    }

    @Test("a progress event refetches unconditionally — folds have no rev")
    internal func progressEventAlwaysRefetches() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        gateway.remoteCourses["crs-p"] = LearningCourseWire(
            id: "crs-p", title: "P", summary: "", rev: 2, modules: [], progress: [:])
        store.setClient(gateway)
        try await Task.sleep(for: .milliseconds(50))

        // Same rev, but now the server copy carries folded progress.
        gateway.remoteCourses["crs-p"] = LearningCourseWire(
            id: "crs-p", title: "P", summary: "", rev: 2, modules: [],
            progress: ["step-1": .dictionary(["attempts": AnyCodable(1)])])
        gateway.eventStream.send((.learningChanged(entity: "progress", id: "crs-p", rev: 0, deleted: false), nil))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.course(id: "crs-p")?.progress["step-1"]?.attempts == 1)
    }

    // MARK: - Push-on-save and upstream deletes

    @Test("saving a course pushes it granularly and adopts the server rev")
    internal func saveCoursePushesGranularly() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)

        let course = sampleCourse()
        store.saveCourse(course)
        try await Task.sleep(for: .milliseconds(100))

        #expect(gateway.courseSetCalls.map(\.id) == [course.id])
        #expect(gateway.moduleSetCalls.count == course.modules.count)
        #expect(gateway.stepSetCalls.count == course.modules.reduce(0) { $0 + $1.steps.count })
        // The server copy is adopted so later events rev-guard correctly.
        #expect(store.course(id: course.id)?.rev == 1)
    }

    @Test("saving a rev-0 deck creates it upstream")
    internal func saveNewDeckPushesUp() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)

        let deck = FlashcardDeck(topic: "New Deck", cards: [Flashcard(front: "f", back: "b", explanation: "")])
        store.saveDeck(deck)
        try await Task.sleep(for: .milliseconds(100))
        #expect(gateway.remoteDecks[deck.id] != nil || gateway.remoteDecks["dk-minted"] != nil)
    }

    @Test("deleting a course or deck removes it locally and upstream")
    internal func deletesPropagateUpstream() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        gateway.remoteCourses["crs-x"] = LearningCourseWire(
            id: "crs-x", title: "X", summary: "", rev: 1, modules: [], progress: [:])
        gateway.remoteDecks["dk-x"] = LearningDeckWire(
            id: "dk-x", topic: "X", rev: 1, cards: [], srs: [:])
        store.injectClientForTesting(gateway)
        await store.pull()
        #expect(store.course(id: "crs-x") != nil)

        store.deleteCourse(id: "crs-x")
        store.deleteDeck(id: "dk-x")
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.course(id: "crs-x") == nil)
        #expect(store.decks["dk-x"] == nil)
        #expect(gateway.remoteCourses["crs-x"] == nil)
        #expect(gateway.remoteDecks["dk-x"] == nil)
    }

    // MARK: - Learner state odds and ends

    @Test("recordLessonRead folds locally and records upstream with a stamp")
    internal func lessonReadRecordsUpstream() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)
        let course = sampleCourse()
        let lessonID = course.modules[0].steps[0].id
        store.saveCourse(course)
        // Let the save's async push+adopt land first — the adopt replaces the
        // local document, so folding before it would be overwritten.
        try await Task.sleep(for: .milliseconds(150))

        store.recordLessonRead(courseID: course.id, stepID: lessonID)
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.course(id: course.id)?.progress[lessonID]?.completedAt != nil)
        let call = try #require(gateway.progressRecordCalls.last)
        #expect(call.kind == "lesson_read")
        #expect(call.at != nil)
    }

    @Test("resetCourseProgress clears locally without rewriting server history")
    internal func resetIsLocalOnly() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)
        var course = sampleCourse()
        course.markLessonRead(stepID: course.modules[0].steps[0].id)
        store.saveCourse(course)
        // As above: the push+adopt is async and replaces the document.
        try await Task.sleep(for: .milliseconds(150))
        let recordedBefore = gateway.progressRecordCalls.count

        store.resetCourseProgress(id: course.id)
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.course(id: course.id)?.progress.isEmpty == true)
        // Monotonic server fold: a reset sends NOTHING upstream.
        #expect(gateway.progressRecordCalls.count == recordedBefore)
    }

    @Test("deleteAttempt removes only the local ledger row")
    internal func deleteAttemptIsLocal() async throws {
        let store = makeStore()
        let question = QuizQuestion(q: "?", options: ["a"], correct: "A", explanation: "", id: "q-1")
        let session = PersistedQuizSession(
            questions: [question], topic: "T",
            selectedAnswers: ["q-1": "A"], score: 1, sourceSessionID: nil)
        store.recordAttempt(session)
        #expect(store.attempts.count == 1)
        store.deleteAttempt(id: session.id)
        #expect(store.attempts.isEmpty)
    }
}
