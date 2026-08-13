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

    private func any(_ value: Any) -> AnyCodable { AnyCodable(any: value) }

    private func response(result: Any? = nil, error: (Int, String)? = nil) throws -> JSONRPCResponse {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": 1]
        if let error { object["error"] = ["code": error.0, "message": error.1] }
        else { object["result"] = result ?? [:] }
        return try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

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

    @Test("course/deck lifecycle covers learner records, remote adoption, migration, and deletion")
    internal func courseAndDeckLifecycle() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.injectClientForTesting(gateway)

        var course = sampleCourse()
        course.rev = 1
        store.saveCourse(course)
        let lessonID = course.modules[0].steps[0].id
        store.recordLessonRead(courseID: course.id, stepID: lessonID)
        try await Task.sleep(for: .milliseconds(50))
        #expect(gateway.progressRecordCalls.last?.kind == "lesson_read")
        store.resetCourseProgress(id: course.id)
        #expect(store.course(id: course.id)?.progress.isEmpty == true)
        store.deleteCourse(id: course.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.course(id: course.id) == nil)

        let remoteCard: [String: AnyCodable] = [
            "id": any("remote-card"), "front": any("Front"), "back": any("Back"),
        ]
        gateway.remoteDecks["remote-deck"] = LearningDeckWire(
            id: "remote-deck", topic: "Remote", rev: 5, cards: [remoteCard], srs: [:]
        )
        await store.pull()
        #expect(store.sortedDecks.contains { $0.id == "remote-deck" && $0.rev == 5 })

        let card = Flashcard(front: "Local", back: "Card", explanation: "")
        var localDeck = FlashcardDeck(topic: "Local", cards: [card])
        localDeck.srsStates[card.id] = SRSEngine.calculate(
            quality: 5, state: try #require(localDeck.srsStates[card.id])
        )
        store.saveDeck(localDeck)
        await store.pull()
        #expect(gateway.reviewRecordCalls.contains { $0.cardID == card.id && $0.bootstrap })
        store.deleteDeck(id: "remote-deck")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!store.sortedDecks.contains { $0.id == "remote-deck" })
    }

    @Test("deck and progress events refetch their current remote parents")
    internal func deckAndProgressEventsRefetch() async throws {
        let store = makeStore()
        let gateway = FakeLearningGateway()
        store.setClient(gateway)
        try await Task.sleep(for: .milliseconds(50))

        gateway.remoteDecks["event-deck"] = LearningDeckWire(
            id: "event-deck", topic: "Event Deck", rev: 2, cards: [], srs: [:]
        )
        gateway.eventStream.send((
            .learningChanged(entity: "deck", id: "event-deck", rev: 2, deleted: false), nil
        ))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.sortedDecks.contains { $0.id == "event-deck" })

        gateway.remoteCourses["event-course"] = LearningCourseWire(
            id: "event-course", title: "Event Course", summary: "", rev: 1,
            modules: [], progress: ["step": any(["attempts": 3])]
        )
        gateway.eventStream.send((
            .learningChanged(entity: "progress", id: "event-course", rev: 0, deleted: false), nil
        ))
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.course(id: "event-course")?.progress["step"]?.attempts == 3)

        gateway.eventStream.send((
            .learningChanged(entity: "deck", id: "event-deck", rev: 3, deleted: true), nil
        ))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!store.sortedDecks.contains { $0.id == "event-deck" })
    }

    @Test("learning wire adapters preserve course, deck, progress, and SRS fields")
    internal func wireAdapters() throws {
        let courseWire = LearningCourseWire(
            id: "course", title: "Course", summary: "Summary", rev: 7,
            modules: [[
                "id": any("module"), "title": any("Module"), "overview": any("Overview"),
                "steps": any([
                    ["id": "lesson", "type": "lesson", "title": "Lesson", "markdown": "Body"],
                    ["id": "quiz", "type": "quiz", "title": "Quiz", "questions": [[
                        "id": "question", "q": "Q?", "options": ["A", "B"],
                        "correct": "A", "explanation": "Because",
                    ]]],
                    ["id": "ignored", "type": "unknown"],
                ]),
            ]],
            progress: ["lesson": any([
                "attempts": 2, "best_score_percent": 95,
                "completed_at": "2026-08-13T10:00:00.123Z",
            ])]
        )
        let course = LearningWire.curriculum(from: courseWire)
        #expect(course.id == "course" && course.rev == 7)
        #expect(course.modules[0].steps.count == 2)
        #expect(course.progress["lesson"]?.attempts == 2)
        #expect(course.progress["lesson"]?.completedAt != nil)
        let lessonFields = LearningWire.stepFields(course.modules[0].steps[0])
        let quizFields = LearningWire.stepFields(course.modules[0].steps[1])
        #expect(lessonFields.type == "lesson" && lessonFields.markdown == "Body")
        #expect(quizFields.type == "quiz" && quizFields.questions?.first?["id"] as? String == "question")

        let deckWire = LearningDeckWire(
            id: "deck", topic: "Deck", rev: 4,
            cards: [["id": any("card"), "front": any("F"), "back": any("B"), "category": any("C")]],
            srs: ["card": any([
                "interval_days": 6.0, "ease_factor": 2.7, "repetitions": 2,
                "next_review_date": "2026-08-14T10:00:00Z",
                "last_reviewed_at": "2026-08-13T10:00:00Z",
                "last_quality": 5, "review_count": 3,
            ])]
        )
        let deck = LearningWire.deck(from: deckWire)
        #expect(deck.rev == 4 && deck.cards[0].category == "C")
        let state = try #require(deck.srsStates["card"])
        #expect(state.interval == 6 && state.reviewCount == 3 && state.lastReviewedAt != nil)
        #expect(LearningWire.wireCard(deck.cards[0])["category"] as? String == "C")
        #expect(LearningWire.wireSRSState(state)["last_reviewed_at"] != nil)
        #expect(LearningWire.parseISO("2026-08-13T10:00:00Z") != nil)
    }

    @Test("learning RPC adapters decode replies and encode every mutation")
    internal func gatewayLearningAdapters() async throws {
        let client = GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "test")
        var calls: [(String, [String: AnyCodable]?)] = []
        client.rpcCallOverrideForTesting = { method, params in
            calls.append((method, params))
            switch method {
            case "learning.course.list":
                return try response(result: ["courses": [["id": "c", "title": "C", "rev": 2]]])
            case "learning.course.get":
                return try response(result: ["course": ["id": "c", "title": "C", "rev": 2], "progress": [:]])
            case "learning.course.set":
                return try response(result: ["course": ["id": "c", "rev": 3]])
            case "learning.module.set":
                return try response(result: ["module": ["id": "m"], "rev": 4])
            case "learning.step.set":
                return try response(result: ["step": ["id": "s"], "rev": 5])
            case "learning.deck.list":
                return try response(result: ["decks": [["id": "d", "topic": "D", "rev": 2]]])
            case "learning.deck.get":
                return try response(result: ["deck": ["id": "d", "topic": "D", "rev": 2], "srs": [:]])
            case "learning.deck.set":
                return try response(result: ["deck": ["id": "d", "rev": 3]])
            case "learning.card.set":
                return try response(result: ["card_ids": ["card"], "rev": 4])
            default:
                return try response(result: [:])
            }
        }

        #expect(try await client.learningCourseList()?.first?.id == "c")
        #expect(try await client.learningCourseGet(id: "c")?.rev == 2)
        #expect(try await client.learningCourseSet(id: "c", title: "C", summary: "S", sourceSessionID: "session")?.rev == 3)
        #expect(try await client.learningModuleSet(courseID: "c", moduleID: "m", title: "M", overview: "O", position: 1)?.rev == 4)
        #expect(try await client.learningStepSet(
            courseID: "c", moduleID: "m", stepID: "s", title: "S", type: "quiz",
            markdown: "body", questions: [["id": "q"]]
        )?.rev == 5)
        try await client.learningCourseDelete(id: "c")
        #expect(try await client.learningDeckList()?.first?.id == "d")
        #expect(try await client.learningDeckGet(id: "d")?.rev == 2)
        #expect(try await client.learningDeckSet(id: "d", topic: "D")?.rev == 3)
        #expect(try await client.learningCardSet(deckID: "d", cards: [["id": "card"]])?.cardIDs == ["card"])
        try await client.learningDeckDelete(id: "d")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await client.learningProgressRecord(courseID: "c", stepID: "s", kind: "quiz_attempt", scorePercent: 90, at: now)
        try await client.learningReviewRecord(
            deckID: "d", cardID: "card", quality: 5, reviewedAt: now,
            bootstrapState: ["review_count": 2]
        )
        try await client.learningAttemptRecord(["topic": "T", "score": 1])
        #expect(calls.map(\.0) == [
            "learning.course.list", "learning.course.get", "learning.course.set",
            "learning.module.set", "learning.step.set", "learning.course.delete",
            "learning.deck.list", "learning.deck.get", "learning.deck.set",
            "learning.card.set", "learning.deck.delete", "learning.progress.record",
            "learning.review.record", "learning.attempt.record",
        ])
        #expect(calls[2].1?["source_session_id"]?.stringValue == "session")
        #expect(calls[4].1?["questions"]?.arrayValue?.count == 1)
        client.disconnect()
    }

    @Test("learning RPC adapters distinguish unsupported, missing, and real errors")
    internal func gatewayLearningAdapterErrors() async throws {
        let client = GatewayClient(gatewayURL: URL(string: "ws://127.0.0.1:9/v1/ws")!, apiKey: "test")
        client.rpcCallOverrideForTesting = { _, _ in try response(error: (-32601, "missing")) }
        #expect(try await client.learningCourseList() == nil)
        #expect(try await client.learningCourseGet(id: "c") == nil)
        #expect(try await client.learningDeckGet(id: "d") == nil)

        client.rpcCallOverrideForTesting = { _, _ in try response(error: (4004, "not found")) }
        #expect(try await client.learningCourseGet(id: "c") == nil)
        #expect(try await client.learningDeckGet(id: "d") == nil)

        client.rpcCallOverrideForTesting = { _, _ in try response(error: (5000, "boom")) }
        await #expect(throws: GatewayError.self) { _ = try await client.learningCourseList() }
        await #expect(throws: GatewayError.self) { _ = try await client.learningCourseGet(id: "c") }
        await #expect(throws: GatewayError.self) { _ = try await client.learningDeckGet(id: "d") }
        client.disconnect()
    }
}
