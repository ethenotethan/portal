import Foundation
import Testing
@testable import Portal

/// The wire ↔ domain translation layer for the learning surface, plus the
/// small decode shims around it (wire structs, the `learning.changed` event,
/// the capability flag, and the untyped-JSON bridge the granular push rides
/// on). All pure — a malformed row must drop, not corrupt the document.
@Suite("Learning wire translation")
internal struct LearningWireTests {

    // MARK: - Course wire → domain

    private func courseWire(modules: [[String: AnyCodable]], progress: [String: AnyCodable] = [:]) -> LearningCourseWire {
        LearningCourseWire(id: "crs-1", title: "T", summary: "S", rev: 3, modules: modules, progress: progress)
    }

    @Test("a course translates modules, lesson and quiz steps, and progress")
    internal func courseRoundTrip() throws {
        let wire = courseWire(
            modules: [[
                "id": AnyCodable("m-1"),
                "title": AnyCodable("Module"),
                "overview": AnyCodable("O"),
                "steps": .array([
                    .dictionary([
                        "id": AnyCodable("s-1"), "type": AnyCodable("lesson"),
                        "title": AnyCodable("Read me"), "markdown": AnyCodable("# hi"),
                    ]),
                    .dictionary([
                        "id": AnyCodable("s-2"), "type": AnyCodable("quiz"),
                        "title": AnyCodable("Check"),
                        "questions": .array([
                            .dictionary([
                                "id": AnyCodable("q-1"), "q": AnyCodable("2+2?"),
                                "options": .array([AnyCodable("3"), AnyCodable("4")]),
                                "correct": AnyCodable("B"),
                                "explanation": AnyCodable("math"),
                            ]),
                        ]),
                    ]),
                ]),
            ]],
            progress: [
                "s-1": .dictionary([
                    "attempts": AnyCodable(2),
                    "best_score_percent": AnyCodable(90),
                    "completed_at": AnyCodable("2026-08-14T10:00:00Z"),
                ]),
                "junk": AnyCodable("not a dict"),
            ]
        )

        let course = LearningWire.curriculum(from: wire)
        #expect(course.id == "crs-1")
        #expect(course.rev == 3)
        #expect(course.modules.count == 1)
        let module = try #require(course.modules.first)
        #expect(module.id == "m-1")
        #expect(module.steps.count == 2)
        guard case .lesson(let markdown) = module.steps[0].kind else {
            Issue.record("first step should be a lesson"); return
        }
        #expect(markdown == "# hi")
        guard case .quiz(let questions) = module.steps[1].kind else {
            Issue.record("second step should be a quiz"); return
        }
        #expect(questions.first?.q == "2+2?")
        #expect(questions.first?.correct == "B")
        // Progress: the valid record lands; the junk value is skipped.
        let record = try #require(course.progress["s-1"])
        #expect(record.attempts == 2)
        #expect(record.bestScorePercent == 90)
        #expect(record.completedAt != nil)
        #expect(course.progress["junk"] == nil)
    }

    @Test("malformed rows drop instead of corrupting the course")
    internal func malformedRowsDrop() {
        let wire = courseWire(modules: [
            [:],  // module with no id → dropped
            [
                "id": AnyCodable("m-2"),
                "steps": .array([
                    // lesson without markdown → dropped
                    .dictionary(["id": AnyCodable("s-a"), "type": AnyCodable("lesson")]),
                    // quiz whose only question is malformed → no questions → dropped
                    .dictionary([
                        "id": AnyCodable("s-b"), "type": AnyCodable("quiz"),
                        "questions": .array([.dictionary(["q": AnyCodable("?")])]),
                    ]),
                    // unknown type → dropped
                    .dictionary(["id": AnyCodable("s-c"), "type": AnyCodable("video")]),
                    // step with no id → dropped
                    .dictionary(["type": AnyCodable("lesson"), "markdown": AnyCodable("x")]),
                ]),
            ],
        ])
        let course = LearningWire.curriculum(from: wire)
        #expect(course.modules.count == 1)
        #expect(course.modules[0].steps.isEmpty)
    }

    // MARK: - Domain → wire

    @Test("stepFields splits lesson and quiz into the wire vocabulary")
    internal func stepFieldsSplit() {
        let lesson = CurriculumStep(title: "L", kind: .lesson(markdown: "body"), id: "s-1")
        let lessonFields = LearningWire.stepFields(lesson)
        #expect(lessonFields.type == "lesson")
        #expect(lessonFields.markdown == "body")
        #expect(lessonFields.questions == nil)

        let question = QuizQuestion(q: "?", options: ["a", "b"], correct: "A", explanation: "e", id: "q-1")
        let quiz = CurriculumStep(title: "Q", kind: .quiz(questions: [question]), id: "s-2")
        let quizFields = LearningWire.stepFields(quiz)
        #expect(quizFields.type == "quiz")
        #expect(quizFields.markdown == nil)
        #expect(quizFields.questions?.count == 1)
        #expect(LearningWire.wireQuestion(question)["correct"] as? String == "A")
        #expect(LearningWire.wireQuestion(question)["options"] as? [String] == ["a", "b"])
    }

    // MARK: - Deck wire → domain

    @Test("a deck translates cards and folds server SRS over the seed")
    internal func deckRoundTrip() throws {
        let wire = LearningDeckWire(
            id: "dk-1", topic: "Swift", rev: 2,
            cards: [
                [
                    "id": AnyCodable("c-1"), "front": AnyCodable("f"), "back": AnyCodable("b"),
                    "explanation": AnyCodable("why"), "category": AnyCodable("lang"),
                ],
                ["front": AnyCodable("no id")],  // dropped
            ],
            srs: [
                "c-1": .dictionary([
                    "interval_days": AnyCodable(3.5),
                    "ease_factor": AnyCodable(2.1),
                    "repetitions": AnyCodable(4),
                    "last_quality": AnyCodable(5),
                    "review_count": AnyCodable(7),
                    "next_review_date": AnyCodable("2026-08-20T00:00:00Z"),
                    "last_reviewed_at": AnyCodable("2026-08-13T00:00:00Z"),
                ]),
                "junk": AnyCodable(1),
            ]
        )
        let deck = LearningWire.deck(from: wire)
        #expect(deck.id == "dk-1")
        #expect(deck.rev == 2)
        #expect(deck.cards.count == 1)
        #expect(deck.cards.first?.explanation == "why")
        #expect(deck.cards.first?.category == "lang")
        let state = try #require(deck.srsStates["c-1"])
        #expect(state.interval == 3.5)
        #expect(state.easeFactor == 2.1)
        #expect(state.repetitions == 4)
        #expect(state.lastQuality == 5)
        #expect(state.reviewCount == 7)
        #expect(state.lastReviewedAt != nil)
        #expect(deck.srsStates["junk"] == nil)
    }

    @Test("wireCard and wireSRSState carry optionals only when present")
    internal func domainToWireOptionals() {
        let bare = Flashcard(front: "f", back: "b", explanation: "")
        #expect(LearningWire.wireCard(bare)["category"] == nil)
        let tagged = Flashcard(front: "f", back: "b", explanation: "", category: "cat")
        #expect(LearningWire.wireCard(tagged)["category"] as? String == "cat")

        var state = SRSState(cardID: "c-1")
        #expect(LearningWire.wireSRSState(state)["last_reviewed_at"] == nil)
        state.lastReviewedAt = Date()
        #expect(LearningWire.wireSRSState(state)["last_reviewed_at"] != nil)
        #expect(LearningWire.wireSRSState(state)["interval_days"] as? Double == state.interval)
    }

    @Test("parseISO accepts fractional and whole-second stamps, rejects garbage")
    internal func parseISOVariants() {
        #expect(LearningWire.parseISO("2026-08-14T10:00:00.123Z") != nil)
        #expect(LearningWire.parseISO("2026-08-14T10:00:00Z") != nil)
        #expect(LearningWire.parseISO("yesterday-ish") == nil)
    }

    // MARK: - Wire structs (the decode half of the RPC surface)

    @Test("wire structs decode their dicts and refuse a missing id")
    internal func wireStructDecoding() {
        let course: [String: AnyCodable] = [
            "id": AnyCodable("crs-9"), "title": AnyCodable("T"),
            "summary": AnyCodable("S"), "rev": AnyCodable(4),
            "modules": .array([.dictionary(["id": AnyCodable("m")])]),
        ]
        let courseWire = LearningCourseWire.from(course, progress: ["s": AnyCodable(1)])
        #expect(courseWire?.id == "crs-9")
        #expect(courseWire?.rev == 4)
        #expect(courseWire?.modules.count == 1)
        #expect(courseWire?.progress.count == 1)
        #expect(LearningCourseWire.from(nil) == nil)
        #expect(LearningCourseWire.from(["title": AnyCodable("no id")]) == nil)
        #expect(LearningCourseWire.from(["id": AnyCodable("")]) == nil)

        let summary = LearningCourseSummary.from(["id": AnyCodable("crs-9"), "rev": AnyCodable(2)])
        #expect(summary?.id == "crs-9")
        #expect(summary?.title.isEmpty == true)
        #expect(summary?.rev == 2)
        #expect(LearningCourseSummary.from(nil) == nil)

        let deck = LearningDeckWire.from(
            ["id": AnyCodable("dk-9"), "topic": AnyCodable("t"),
             "cards": .array([.dictionary(["id": AnyCodable("c")])])],
            srs: ["c": AnyCodable(1)]
        )
        #expect(deck?.id == "dk-9")
        #expect(deck?.cards.count == 1)
        #expect(deck?.srs.count == 1)
        #expect(LearningDeckWire.from(["topic": AnyCodable("no id")]) == nil)

        let deckSummary = LearningDeckSummary.from(["id": AnyCodable("dk-9"), "topic": AnyCodable("t"), "rev": AnyCodable(1)])
        #expect(deckSummary?.topic == "t")
        #expect(LearningDeckSummary.from(nil) == nil)
    }

    // MARK: - The learning.changed event

    @Test("learning.changed decodes entity, id, rev, and deleted")
    internal func learningChangedDecodes() {
        let event = GatewayEvent.from(type: "learning.changed", payload: .dictionary([
            "entity": AnyCodable("course"), "id": AnyCodable("crs-1"),
            "rev": AnyCodable(7), "deleted": AnyCodable(true),
        ]))
        guard case .learningChanged(let entity, let id, let rev, let deleted) = event else {
            Issue.record("expected learningChanged, got \(event.debugName)"); return
        }
        #expect(entity == "course")
        #expect(id == "crs-1")
        #expect(rev == 7)
        #expect(deleted)

        // Field defaults: a payload that names nothing still decodes.
        let bare = GatewayEvent.from(type: "learning.changed", payload: .dictionary([:]))
        guard case .learningChanged(let e2, let i2, let r2, let d2) = bare else {
            Issue.record("expected learningChanged"); return
        }
        #expect(e2.isEmpty && i2.isEmpty && r2 == 0 && d2 == false)
    }

    // MARK: - Capability flag

    @Test("supportsLearning keys on a learning.* capability name")
    internal func supportsLearningFlag() {
        let with = GatewayCapabilities.from(
            result: .dictionary(["methods": .array([AnyCodable("learning.course.list")])]),
            method: "gateway.capabilities"
        )
        #expect(with.supportsLearning)
        let without = GatewayCapabilities.from(
            result: .dictionary(["methods": .array([AnyCodable("session.create")])]),
            method: "gateway.capabilities"
        )
        #expect(!without.supportsLearning)
    }

    // MARK: - Untyped-JSON bridge (the granular push's param encoding)

    @Test("AnyCodable(any:) bridges nested untyped JSON and nulls the unrepresentable")
    internal func anyCodableBridge() {
        let bridged = AnyCodable(any: [
            "s": "text",
            "i": 3,
            "d": 3.5,
            "b": true,
            "arr": [1, "two"],
            "nested": ["k": "v"],
            "wrapped": AnyCodable("already typed"),
            "bad": Date(),  // unrepresentable leaf → .null, not a thrown request
        ] as [String: Any])
        let dict = bridged.dictionaryValue
        #expect(dict?["s"]?.stringValue == "text")
        #expect(dict?["i"]?.intValue == 3)
        #expect(dict?["d"]?.doubleValue == 3.5)
        #expect(dict?["b"]?.boolValue == true)
        #expect(dict?["arr"]?.arrayValue?.count == 2)
        #expect(dict?["nested"]?.dictionaryValue?["k"]?.stringValue == "v")
        #expect(dict?["wrapped"]?.stringValue == "already typed")
        #expect(dict?["bad"]?.stringValue == nil)
    }
}
