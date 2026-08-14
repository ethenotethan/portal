import Foundation
import Testing
@testable import Portal

@Suite("Learning Wire Contract")
internal struct LearningWireTests {
    private func any(_ value: Any) -> AnyCodable { AnyCodable(any: value) }

    @Test("course translation keeps valid content, progress, and drops malformed steps")
    internal func courseTranslation() throws {
        let modules: [[String: AnyCodable]] = [
            [
                "id": any("mod-1"),
                "title": any("Module"),
                "overview": any("Overview"),
                "steps": any([
                    ["id": "lesson-1", "title": "Read", "type": "lesson", "markdown": "# Hi"],
                    ["id": "quiz-1", "title": "Check", "type": "quiz", "questions": [
                        ["id": "q-1", "q": "Why?", "options": ["A", "B"], "correct": "A", "explanation": "Because"]
                    ]],
                    ["id": "bad-lesson", "type": "lesson"],
                    ["id": "bad-quiz", "type": "quiz", "questions": []],
                    ["id": "unknown", "type": "video"],
                    ["title": "missing id", "type": "lesson", "markdown": "x"]
                ])
            ],
            ["title": any("missing module id")]
        ]
        let progress: [String: AnyCodable] = [
            "lesson-1": any([
                "attempts": 2,
                "best_score_percent": 90,
                "completed_at": "2026-08-14T12:00:00.123Z"
            ]),
            "quiz-1": any(["completed_at": "2026-08-14T12:00:00Z"]),
            "invalid": any("not-a-record")
        ]
        let course = LearningWire.curriculum(from: LearningCourseWire(
            id: "course-1", title: "Course", summary: "Summary", rev: 7,
            modules: modules, progress: progress
        ))

        #expect(course.id == "course-1")
        #expect(course.rev == 7)
        #expect(course.modules.count == 1)
        #expect(course.modules[0].steps.count == 2)
        #expect(course.progress["lesson-1"]?.attempts == 2)
        #expect(course.progress["lesson-1"]?.completedAt != nil)
        #expect(course.progress["quiz-1"]?.completedAt != nil)
        #expect(course.progress["invalid"] == nil)

        let lesson = LearningWire.stepFields(course.modules[0].steps[0])
        #expect(lesson.type == "lesson")
        #expect(lesson.markdown == "# Hi")
        let quiz = LearningWire.stepFields(course.modules[0].steps[1])
        #expect(quiz.type == "quiz")
        #expect(quiz.questions?.first?["id"] as? String == "q-1")
    }

    @Test("deck translation and outbound SRS shapes preserve scheduling state")
    internal func deckTranslation() throws {
        let deck = LearningWire.deck(from: LearningDeckWire(
            id: "deck-1", topic: "Topic", rev: 4,
            cards: [
                ["id": any("card-1"), "front": any("Front"), "back": any("Back"),
                 "category": any("cat")],
                ["id": any("bad")]
            ],
            srs: [
                "card-1": any([
                    "interval_days": 6.5,
                    "ease_factor": 2.7,
                    "repetitions": 3,
                    "last_quality": 5,
                    "review_count": 4,
                    "next_review_date": "2026-08-20T12:00:00.123Z",
                    "last_reviewed_at": "2026-08-14T12:00:00Z"
                ]),
                "bad": any("not-a-record")
            ]
        ))

        #expect(deck.cards.count == 1)
        let state = try #require(deck.srsStates["card-1"])
        #expect(state.interval == 6.5)
        #expect(state.repetitions == 3)
        #expect(state.reviewCount == 4)
        #expect(state.lastReviewedAt != nil)
        let card = LearningWire.wireCard(deck.cards[0])
        #expect(card["category"] as? String == "cat")
        let wireState = LearningWire.wireSRSState(state)
        #expect(wireState["review_count"] as? Int == 4)
        #expect(wireState["last_reviewed_at"] is String)
        #expect(LearningWire.parseISO("not-a-date") == nil)
    }

    @Test("wire DTO factories and heterogeneous bridge reject bad ids and preserve JSON values")
    internal func factoriesAndAnyBridge() throws {
        #expect(LearningCourseWire.from(nil) == nil)
        #expect(LearningCourseWire.from(["id": any("")]) == nil)
        let course = try #require(LearningCourseWire.from([
            "id": any("c"), "title": any("T"), "summary": any("S"), "rev": any(2),
            "modules": any([["id": "m"]])
        ], progress: ["s": any(["attempts": 1])]))
        #expect(course.modules.count == 1)
        #expect(course.progress["s"] != nil)

        #expect(LearningCourseSummary.from(nil) == nil)
        #expect(LearningCourseSummary.from(["id": any("")]) == nil)
        #expect(LearningCourseSummary.from(["id": any("c")])?.rev == 0)
        #expect(LearningDeckWire.from(nil) == nil)
        #expect(LearningDeckWire.from(["id": any("")]) == nil)
        #expect(LearningDeckWire.from(["id": any("d"), "cards": any([])])?.topic.isEmpty == true)
        #expect(LearningDeckSummary.from(nil) == nil)
        #expect(LearningDeckSummary.from(["id": any("")]) == nil)
        #expect(LearningDeckSummary.from(["id": any("d"), "topic": any("T"), "rev": any(3)])?.rev == 3)

        let bridged = AnyCodable(any: [
            "string": "x", "bool": true, "int": 2, "double": 1.5,
            "array": ["a", 1] as [Any], "nested": ["ok": true],
            "existing": AnyCodable.string("kept"), "unknown": Date()
        ])
        let dict = try #require(bridged.dictionaryValue)
        #expect(dict["string"] == .string("x"))
        #expect(dict["bool"] == .bool(true))
        #expect(dict["int"] == .int(2))
        #expect(dict["double"] == .double(1.5))
        #expect(dict["array"]?.arrayValue?.count == 2)
        #expect(dict["nested"]?.dictionaryValue?["ok"] == .bool(true))
        #expect(dict["existing"] == .string("kept"))
        #expect(dict["unknown"] == .null)
    }

    @Test("learning.changed parses every metadata field")
    internal func eventParsing() {
        let event = GatewayEvent.from(type: "learning.changed", payload: any([
            "entity": "course", "id": "course-1", "rev": 8, "deleted": true
        ]))
        guard case .learningChanged(let entity, let id, let rev, let deleted) = event else {
            Issue.record("expected learning.changed")
            return
        }
        #expect(entity == "course")
        #expect(id == "course-1")
        #expect(rev == 8)
        #expect(deleted)
        #expect(event.debugName == "learning.changed")
    }

    @Test("learning capability, string quiz ids, and isolated disk misses are exercised")
    @MainActor
    internal func adjacentLearningSurfaces() {
        let enabled = GatewayCapabilities(
            gatewayVersion: nil, agentVersion: nil,
            capabilityNames: ["learning.course.list"],
            hasImageInput: false, hasACPImagePrompts: false,
            source: .gateway(method: "gateway.capabilities"))
        #expect(enabled.supportsLearning)
        var disabled = enabled
        disabled.capabilityNames = ["wiki.scan"]
        #expect(!disabled.supportsLearning)

        let question = QuizQuestion(
            q: "?", options: ["A", "B", "C", "D"],
            correct: "A", explanation: "", id: "question-1")
        var state = QuizState(questions: [question], topic: "T")
        let missingAnswer = state.answer(questionID: "missing", option: "A")
        let correctAnswer = state.answer(questionID: "question-1", option: "A")
        #expect(!missingAnswer)
        #expect(correctAnswer)
        #expect(state.selectedAnswers["question-1"] == "A")
        #expect(state.answeredQuestions.contains("question-1"))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("learning-adjacent-\(UUID().uuidString)")
        #expect(CurriculumStore(directory: root.appendingPathComponent("courses"))
            .load(id: "missing") == nil)
        #expect(SRSStore(directory: root.appendingPathComponent("decks"))
            .loadDeck(id: "missing") == nil)
    }
}

@Suite("Learning Gateway RPC")
@MainActor
internal struct LearningGatewayRPCTests {
    private func makeClient() throws -> GatewayClient {
        GatewayClient(
            gatewayURL: try #require(URL(string: "ws://127.0.0.1:9/v1/ws")),
            apiKey: "test"
        )
    }

    private func response(result: Any? = nil, errorCode: Int? = nil) -> JSONRPCResponse {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": 1]
        if let errorCode {
            object["error"] = ["code": errorCode, "message": "failure"]
        } else {
            object["result"] = result ?? [:]
        }
        // Test-only JSON is composed exclusively from JSON-compatible literals.
        // swiftlint:disable:next force_try
        let data = try! JSONSerialization.data(withJSONObject: object)
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(JSONRPCResponse.self, from: data)
    }

    @Test("all learning methods emit granular documented parameters and decode replies")
    internal func allMethods() async throws {
        let client = try makeClient()
        var calls: [(String, [String: AnyCodable])] = []
        client.learningCallOverrideForTesting = { method, params in
            calls.append((method, params))
            switch method {
            case "learning.course.list":
                return response(result: ["courses": [["id": "c", "title": "Course", "rev": 2], ["title": "bad"]]])
            case "learning.course.get":
                return response(result: ["course": ["id": "c", "title": "Course", "summary": "S", "rev": 2,
                                                       "modules": []],
                                         "progress": ["step": ["attempts": 1]]])
            case "learning.course.set":
                return response(result: ["course": ["id": "c", "rev": 3]])
            case "learning.module.set":
                return response(result: ["module": ["id": "m"], "rev": 4])
            case "learning.step.set":
                return response(result: ["step": ["id": "s"], "rev": 5])
            case "learning.deck.list":
                return response(result: ["decks": [["id": "d", "topic": "Deck", "rev": 2], ["topic": "bad"]]])
            case "learning.deck.get":
                return response(result: ["deck": ["id": "d", "topic": "Deck", "rev": 2, "cards": []], "srs": [:]])
            case "learning.deck.set":
                return response(result: ["deck": ["id": "d", "rev": 3]])
            case "learning.card.set":
                return response(result: ["card_ids": ["a", "b"], "rev": 4])
            default:
                return response(result: [:])
            }
        }

        #expect(try await client.learningCourseList()?.first?.id == "c")
        #expect(try await client.learningCourseGet(id: "c")?.progress["step"] != nil)
        let course = try #require(try await client.learningCourseSet(
            id: "c", title: "Course", summary: "S", sourceSessionID: "session"))
        #expect(course.rev == 3)
        let module = try #require(try await client.learningModuleSet(
            courseID: "c", moduleID: "m", title: "M", overview: "O", position: 1))
        #expect(module.rev == 4)
        let step = try #require(try await client.learningStepSet(
            courseID: "c", moduleID: "m", stepID: "s", title: "S", type: "quiz",
            markdown: "body", questions: [["id": "q"]]))
        #expect(step.rev == 5)
        try await client.learningCourseDelete(id: "c")

        #expect(try await client.learningDeckList()?.first?.id == "d")
        #expect(try await client.learningDeckGet(id: "d")?.id == "d")
        #expect(try await client.learningDeckSet(id: "d", topic: "Deck")?.rev == 3)
        try await client.learningDeckDelete(id: "d")
        #expect(try await client.learningCardSet(deckID: "d", cards: [["id": "a"], ["id": "b"]])?.cardIDs == ["a", "b"])

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try await client.learningProgressRecord(
            courseID: "c", stepID: "s", kind: "quiz_attempt", scorePercent: 90, at: date)
        try await client.learningReviewRecord(
            deckID: "d", cardID: "a", quality: 5, reviewedAt: date, bootstrapState: ["review_count": 1])
        try await client.learningAttemptRecord(["topic": "T", "score": 1])

        #expect(calls.map(\.0) == [
            "learning.course.list", "learning.course.get", "learning.course.set",
            "learning.module.set", "learning.step.set", "learning.course.delete",
            "learning.deck.list", "learning.deck.get", "learning.deck.set",
            "learning.deck.delete", "learning.card.set", "learning.progress.record",
            "learning.review.record", "learning.attempt.record"
        ])
        #expect(calls[2].1["source_session_id"] == .string("session"))
        #expect(calls[3].1["position"] == .int(1))
        #expect(calls[4].1["questions"]?.arrayValue?.count == 1)
        #expect(calls[11].1["at"]?.stringValue != nil)
        #expect(calls[12].1["state"]?.dictionaryValue?["review_count"] == .int(1))
    }

    @Test("optional mutation fields may be omitted and malformed mutation replies return nil")
    internal func optionalAndMalformedReplies() async throws {
        let client = try makeClient()
        var calls: [(String, [String: AnyCodable])] = []
        client.learningCallOverrideForTesting = { method, params in
            calls.append((method, params))
            return response(result: [:])
        }

        #expect(try await client.learningCourseSet(
            id: nil, title: "T", summary: "S", sourceSessionID: nil) == nil)
        #expect(try await client.learningModuleSet(
            courseID: "c", moduleID: nil, title: nil, overview: nil) == nil)
        #expect(try await client.learningStepSet(
            courseID: "c", moduleID: "m", stepID: nil, title: nil,
            type: nil, markdown: nil, questions: nil) == nil)
        #expect(try await client.learningDeckSet(id: nil, topic: "D") == nil)
        #expect(try await client.learningCourseGet(id: "missing") == nil)
        #expect(try await client.learningDeckGet(id: "missing") == nil)
        #expect(try await client.learningCourseList()?.isEmpty == true)
        #expect(try await client.learningDeckList()?.isEmpty == true)
        let cards = try #require(try await client.learningCardSet(deckID: "d", cards: []))
        #expect(cards.cardIDs.isEmpty)
        #expect(cards.rev == 0)
        try await client.learningProgressRecord(
            courseID: "c", stepID: "s", kind: "lesson_read", scorePercent: nil, at: nil)
        try await client.learningReviewRecord(
            deckID: "d", cardID: "a", quality: 3, reviewedAt: Date(), bootstrapState: nil)

        #expect(calls[0].1["id"] == nil)
        #expect(calls[0].1["source_session_id"] == nil)
        #expect(calls[1].1["title"] == nil)
        #expect(calls[2].1["questions"] == nil)
        #expect(calls[3].1["id"] == nil)
        #expect(calls[9].1["score_percent"] == nil)
        #expect(calls[9].1["at"] == nil)
        #expect(calls[10].1["state"] == nil)
    }

    @Test("method-not-found and missing entities return nil while real RPC errors throw")
    internal func errors() async throws {
        let client = try makeClient()
        client.learningCallOverrideForTesting = { _, _ in response(errorCode: -32601) }
        #expect(try await client.learningCourseList() == nil)
        #expect(try await client.learningCourseGet(id: "missing") == nil)
        #expect(try await client.learningDeckGet(id: "missing") == nil)

        client.learningCallOverrideForTesting = { _, _ in response(errorCode: 4004) }
        #expect(try await client.learningCourseGet(id: "missing") == nil)
        #expect(try await client.learningDeckGet(id: "missing") == nil)

        client.learningCallOverrideForTesting = { _, _ in response(errorCode: 5000) }
        await #expect(throws: GatewayError.self) { _ = try await client.learningCourseList() }
        await #expect(throws: GatewayError.self) { _ = try await client.learningCourseGet(id: "c") }
        await #expect(throws: GatewayError.self) { _ = try await client.learningDeckGet(id: "d") }
    }
}
