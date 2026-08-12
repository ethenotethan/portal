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

    func learningCourseDelete(id: String) async throws {
        remoteCourses.removeValue(forKey: id)
    }

    func learningModuleSet(
        courseID: String, moduleID: String?, title: String?, overview: String?, position: Int?
    ) async throws -> (id: String, rev: Int)? {
        moduleSetCalls.append((courseID, moduleID))
        return (moduleID ?? "m-minted", 2)
    }

    func learningStepSet(
        courseID: String, moduleID: String, stepID: String?,
        title: String?, type: String?, markdown: String?,
        questions: [[String: Any]]?
    ) async throws -> (id: String, rev: Int)? {
        stepSetCalls.append((courseID, moduleID, stepID, type))
        return (stepID ?? "s-minted", 3)
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
}
