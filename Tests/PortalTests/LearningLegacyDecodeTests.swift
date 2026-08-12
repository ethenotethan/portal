import Foundation
import Testing
@testable import Portal

/// The String-id migration's sharpest edge: Swift encodes `[UUID: V]`
/// dictionaries as FLAT ARRAYS (`[key, value, key, value]`), not objects,
/// so every curriculum/deck/quiz file saved before the migration carries
/// that array form on disk. These tests decode byte-exact replicas of the
/// legacy format — if any shim regresses, the user's progress, SRS
/// history, or quiz records silently vanish (the list loaders drop files
/// that fail to decode).
@Suite("Learning legacy decode")
internal struct LearningLegacyDecodeTests {

    /// A JSON encoder matching the stores' default (no custom strategies).
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Fixtures (verbatim legacy shapes)

    /// Legacy curriculum JSON: UUID ids, progress as a UUID-keyed dict —
    /// which Swift encodes as the flat array this fixture reproduces.
    private func legacyCurriculumJSON(stepID: UUID) -> String {
        """
        {
          "id": "1B671A64-40D5-491E-99B0-DA01FF1F3341",
          "title": "Legacy Course",
          "summary": "Saved before the String-id migration",
          "created": 700000000,
          "sourceSessionID": null,
          "modules": [
            {
              "id": "2B671A64-40D5-491E-99B0-DA01FF1F3342",
              "title": "Module One",
              "overview": "",
              "steps": [
                {
                  "id": "\(stepID.uuidString)",
                  "title": "Lesson One",
                  "kind": {"type": "lesson", "markdown": "# Hello"}
                }
              ]
            }
          ],
          "progress": [
            "\(stepID.uuidString)",
            {"completedAt": 700000100, "bestScorePercent": 90, "attempts": 2}
          ]
        }
        """
    }

    @Test("legacy curriculum decodes with array-encoded progress intact")
    internal func decodesLegacyCurriculum() throws {
        let stepID = UUID()
        let data = try #require(legacyCurriculumJSON(stepID: stepID).data(using: .utf8))
        let course = try decoder.decode(Curriculum.self, from: data)

        #expect(course.id == "1B671A64-40D5-491E-99B0-DA01FF1F3341")
        #expect(course.rev == 0, "legacy files predate rev — must read as local-only")
        #expect(course.modules.count == 1)
        #expect(course.modules[0].steps[0].id == stepID.uuidString)

        let record = try #require(course.progress[stepID.uuidString])
        #expect(record.bestScorePercent == 90)
        #expect(record.attempts == 2)
        #expect(record.completedAt != nil)
    }

    @Test("legacy deck decodes with array-encoded srsStates intact")
    internal func decodesLegacyDeck() throws {
        let cardID = UUID()
        let json = """
        {
          "id": "3B671A64-40D5-491E-99B0-DA01FF1F3343",
          "topic": "Legacy Deck",
          "created": 700000000,
          "sourceSessionID": null,
          "cards": [
            {
              "id": "\(cardID.uuidString)",
              "front": "F", "back": "B", "explanation": "E",
              "category": null, "tags": []
            }
          ],
          "srsStates": [
            "\(cardID.uuidString)",
            {"cardID": "\(cardID.uuidString)", "interval": 6, "easeFactor": 2.7,
             "repetitions": 2, "nextReviewDate": 700600000,
             "lastReviewedAt": 700000000, "lastQuality": 5, "reviewCount": 4}
          ]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let deck = try decoder.decode(FlashcardDeck.self, from: data)

        #expect(deck.rev == 0)
        #expect(deck.cards[0].id == cardID.uuidString)
        let state = try #require(deck.srsStates[cardID.uuidString])
        #expect(state.interval == 6)
        #expect(state.easeFactor == 2.7)
        #expect(state.reviewCount == 4, "SRS history must survive the migration")
    }

    @Test("legacy quiz session decodes with array-encoded selectedAnswers")
    internal func decodesLegacyQuizSession() throws {
        let questionID = UUID()
        let json = """
        {
          "id": "4B671A64-40D5-491E-99B0-DA01FF1F3344",
          "topic": "Legacy Quiz",
          "score": 1,
          "completedAt": 700000000,
          "sourceSessionID": null,
          "questions": [
            {"id": "\(questionID.uuidString)", "q": "Q?",
             "options": ["A) a", "B) b", "C) c", "D) d"],
             "correct": "A", "explanation": ""}
          ],
          "selectedAnswers": ["\(questionID.uuidString)", "A"]
        }
        """
        let data = try #require(json.data(using: .utf8))
        let session = try decoder.decode(PersistedQuizSession.self, from: data)

        #expect(session.selectedAnswers[questionID.uuidString] == "A")
        #expect(session.wrongAnswers.isEmpty, "the A answer was correct")
    }

    // MARK: - Round-trip (modern format)

    @Test("a modern course round-trips through Codable unchanged")
    internal func modernCourseRoundTrips() throws {
        var course = Curriculum(
            title: "Modern", summary: "s",
            modules: [CurriculumModule(
                title: "M", overview: "",
                steps: [CurriculumStep(title: "L", kind: .lesson(markdown: "body"))]
            )]
        )
        course.markLessonRead(stepID: course.modules[0].steps[0].id)
        course.rev = 3

        let data = try encoder.encode(course)
        let decoded = try decoder.decode(Curriculum.self, from: data)
        #expect(decoded == course)
        #expect(decoded.rev == 3)
        #expect(decoded.progress.count == 1)
    }

    @Test("a modern deck round-trips through Codable unchanged")
    internal func modernDeckRoundTrips() throws {
        let card = Flashcard(front: "f", back: "b", explanation: "e")
        var deck = FlashcardDeck(topic: "t", cards: [card])
        deck.srsStates[card.id] = SRSEngine.calculate(quality: 5, state: SRSState(cardID: card.id))
        deck.rev = 2

        let data = try encoder.encode(deck)
        let decoded = try decoder.decode(FlashcardDeck.self, from: data)
        #expect(decoded == deck)
    }
}
