import Foundation

/// Translation between the gateway learning wire shapes and the domain
/// models. Kept in one place so the wire vocabulary (`type` / `markdown` /
/// `questions`, snake_case SRS fields) can't drift into views.
///
/// The wire step shape was deliberately chosen to match the hand-written
/// `CurriculumStepKind` Codable discriminator, so translation is field
/// mapping, not restructuring.
internal enum LearningWire {

    // MARK: Course wire → domain

    internal static func curriculum(from wire: LearningCourseWire) -> Curriculum {
        let modules: [CurriculumModule] = wire.modules.compactMap { rawModule in
            guard let moduleID = rawModule["id"]?.stringValue else { return nil }
            let steps: [CurriculumStep] = (rawModule["steps"]?.arrayValue ?? [])
                .compactMap { step(from: $0.dictionaryValue) }
            return CurriculumModule(
                title: rawModule["title"]?.stringValue ?? "",
                overview: rawModule["overview"]?.stringValue ?? "",
                steps: steps,
                id: moduleID
            )
        }
        var course = Curriculum(
            title: wire.title,
            summary: wire.summary,
            modules: modules,
            id: wire.id
        )
        course.rev = wire.rev
        course.progress = progressMap(from: wire.progress)
        return course
    }

    private static func step(from d: [String: AnyCodable]?) -> CurriculumStep? {
        guard let d, let id = d["id"]?.stringValue,
              let type = d["type"]?.stringValue else { return nil }
        let title = d["title"]?.stringValue ?? ""
        switch type {
        case "lesson":
            guard let markdown = d["markdown"]?.stringValue else { return nil }
            return CurriculumStep(title: title, kind: .lesson(markdown: markdown), id: id)
        case "quiz":
            let questions: [QuizQuestion] = (d["questions"]?.arrayValue ?? []).compactMap {
                guard let q = $0.dictionaryValue,
                      let prompt = q["q"]?.stringValue,
                      let options = q["options"]?.arrayValue?.compactMap({ $0.stringValue }),
                      let correct = q["correct"]?.stringValue else { return nil }
                return QuizQuestion(
                    q: prompt, options: options, correct: correct,
                    explanation: q["explanation"]?.stringValue ?? "",
                    id: q["id"]?.stringValue ?? UUID().uuidString
                )
            }
            guard !questions.isEmpty else { return nil }
            return CurriculumStep(title: title, kind: .quiz(questions: questions), id: id)
        default:
            return nil
        }
    }

    internal static func progressMap(from d: [String: AnyCodable]) -> [String: CurriculumStepProgress] {
        var out: [String: CurriculumStepProgress] = [:]
        for (stepID, value) in d {
            guard let record = value.dictionaryValue else { continue }
            var progress = CurriculumStepProgress()
            progress.attempts = record["attempts"]?.intValue ?? 0
            progress.bestScorePercent = record["best_score_percent"]?.intValue
            if let stamp = record["completed_at"]?.stringValue {
                progress.completedAt = parseISO(stamp)
            }
            out[stepID] = progress
        }
        return out
    }

    // MARK: Domain → wire (the granular migration push)

    /// One quiz question as the wire dict `learning.step.set` expects.
    internal static func wireQuestion(_ q: QuizQuestion) -> [String: Any] {
        [
            "id": q.id,
            "q": q.q,
            "options": q.options,
            "correct": q.correct,
            "explanation": q.explanation,
        ]
    }

    /// Step payload fields (beyond ids) for `learning.step.set`.
    internal static func stepFields(_ step: CurriculumStep)
        -> (type: String, markdown: String?, questions: [[String: Any]]?) {
        switch step.kind {
        case .lesson(let markdown):
            return ("lesson", markdown, nil)
        case .quiz(let questions):
            return ("quiz", nil, questions.map(wireQuestion))
        }
    }

    // MARK: Deck wire → domain

    internal static func deck(from wire: LearningDeckWire) -> FlashcardDeck {
        let cards: [Flashcard] = wire.cards.compactMap { raw in
            guard let id = raw["id"]?.stringValue,
                  let front = raw["front"]?.stringValue,
                  let back = raw["back"]?.stringValue else { return nil }
            return Flashcard(
                front: front, back: back,
                explanation: raw["explanation"]?.stringValue ?? back,
                category: raw["category"]?.stringValue,
                id: id
            )
        }
        var deck = FlashcardDeck(topic: wire.topic, cards: cards, id: wire.id)
        deck.rev = wire.rev
        // Server SRS overrides the freshly-seeded default states card by card;
        // cards the server has never seen reviewed keep their due-now seed.
        for (cardID, value) in wire.srs {
            guard let record = value.dictionaryValue else { continue }
            var state = SRSState(cardID: cardID)
            state.interval = record["interval_days"]?.doubleValue ?? 0
            state.easeFactor = record["ease_factor"]?.doubleValue ?? SRSEngine.defaultEaseFactor
            state.repetitions = record["repetitions"]?.intValue ?? 0
            state.lastQuality = record["last_quality"]?.intValue ?? 0
            state.reviewCount = record["review_count"]?.intValue ?? 0
            if let stamp = record["next_review_date"]?.stringValue, let date = parseISO(stamp) {
                state.nextReviewDate = date
            }
            if let stamp = record["last_reviewed_at"]?.stringValue {
                state.lastReviewedAt = parseISO(stamp)
            }
            deck.srsStates[cardID] = state
        }
        return deck
    }

    /// One flashcard as the wire dict `learning.card.set` expects.
    internal static func wireCard(_ card: Flashcard) -> [String: Any] {
        var out: [String: Any] = ["id": card.id, "front": card.front, "back": card.back]
        if let category = card.category { out["category"] = category }
        return out
    }

    /// One local SM-2 state as the bootstrap-import dict for
    /// `learning.review.record`'s `state` param (snake_case wire fields).
    internal static func wireSRSState(_ state: SRSState) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        var out: [String: Any] = [
            "interval_days": state.interval,
            "ease_factor": state.easeFactor,
            "repetitions": state.repetitions,
            "next_review_date": iso.string(from: state.nextReviewDate),
            "last_quality": state.lastQuality,
            "review_count": state.reviewCount,
        ]
        if let last = state.lastReviewedAt {
            out["last_reviewed_at"] = iso.string(from: last)
        }
        return out
    }

    // MARK: Shared

    internal static func parseISO(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
