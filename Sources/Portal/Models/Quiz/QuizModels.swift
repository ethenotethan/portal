import Foundation

/// A single quiz question with 4 multiple-choice options.
///
/// `id` is a String, not a UUID: question identity now round-trips through
/// the gateway learning store, whose ids are server-minted strings
/// (`q-<hex8>`). Locally-minted questions use a UUID string, which the
/// gateway id grammar accepts verbatim — so pushing a local quiz up needs
/// no id translation.
struct QuizQuestion: Identifiable, Codable, Equatable {
    internal let id: String
    let q: String
    let options: [String]
    let correct: String       // "A", "B", "C", or "D"
    let explanation: String

    internal init(q: String, options: [String], correct: String, explanation: String, id: String = UUID().uuidString) {
        self.id = id
        self.q = q
        self.options = options
        self.correct = correct
        self.explanation = explanation
    }
    // No decode shim needed for `id` itself: Swift encodes UUID as a JSON
    // string, so legacy files decode into the String field unchanged.

    /// The full answer text for the correct option (e.g. "Paris" when correct = "A" and options[A] = "Paris").
    var correctAnswer: String {
        guard let idx = ["A", "B", "C", "D"].firstIndex(of: correct),
              idx < options.count else { return correct }
        return options[idx]
    }
}

/// Raw JSON structure for parsing agent quiz responses.
struct QuizResponse: Codable {
    let questions: [QuizQuestionRaw]

    struct QuizQuestionRaw: Codable {
        let q: String
        let options: [String]
        let correct: String
        let explanation: String

        func toQuizQuestion() -> QuizQuestion {
            QuizQuestion(q: q, options: options, correct: correct, explanation: explanation)
        }
    }
}

/// The complete runtime state of a quiz session.
struct QuizState {
    let questions: [QuizQuestion]
    let topic: String
    var currentIndex: Int = 0
    internal var selectedAnswers: [String: String] = [:]  // questionID → selected option letter
    internal var answeredQuestions: Set<String> = []
    var score: Int = 0
    var isComplete: Bool = false

    var currentQuestion: QuizQuestion? {
        guard currentIndex < questions.count else { return nil }
        return questions[currentIndex]
    }

    var progress: (current: Int, total: Int) {
        let answered = answeredQuestions.count
        return (min(answered + 1, questions.count), questions.count)
    }

    var wrongAnswers: [(question: QuizQuestion, selected: String)] {
        questions.compactMap { question in
            guard let selected = selectedAnswers[question.id],
                  selected != question.correct else { return nil }
            return (question, selected)
        }
    }

    /// Record an answer and return whether it was correct.
    internal mutating func answer(questionID: String, option: String) -> Bool {
        guard let question = questions.first(where: { $0.id == questionID }) else { return false }
        selectedAnswers[questionID] = option
        answeredQuestions.insert(questionID)
        let isCorrect = option == question.correct
        if isCorrect {
            score += 1
        }
        return isCorrect
    }

    mutating func advance() {
        currentIndex += 1
        if currentIndex >= questions.count {
            isComplete = true
        }
    }
}

// MARK: - JSON Extraction Helper

extension QuizResponse {
    /// Attempt to parse quiz JSON from an agent's response text.
    /// Handles common formatting issues like markdown code fences and trailing commas.
    static func extract(from text: String) -> [QuizQuestion]? {
        // Try to find JSON block in markdown fences or raw text
        var jsonString = text

        // Strip markdown code fences
        if let range = text.range(of: "```json") {
            let start = range.upperBound
            if let end = text[start...].range(of: "```") {
                jsonString = String(text[start..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if let range = text.range(of: "```") {
            let start = range.upperBound
            if let end = text[start...].range(of: "```") {
                jsonString = String(text[start..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // Also try to locate a JSON object directly
        let attempts: [String] = [
            jsonString,
            extractBracedJSON(from: text) ?? jsonString
        ]

        for attempt in attempts {
            guard let data = attempt.data(using: .utf8) else { continue }

            // Try strict parse first
            if let response = try? JSONDecoder().decode(QuizResponse.self, from: data) {
                return response.questions.map { $0.toQuizQuestion() }
            }

            // Try lenient parse with JSONSerialization
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let questionsArray = json["questions"] as? [[String: Any]] {
                return questionsArray.compactMap { dict in
                    guard let q = dict["q"] as? String,
                          let options = dict["options"] as? [String],
                          let correct = dict["correct"] as? String,
                          let explanation = dict["explanation"] as? String,
                          options.count == 4 else { return nil }
                    return QuizQuestion(q: q, options: options, correct: correct, explanation: explanation)
                }
            }

            // Try array of questions directly
            if let questionsArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return questionsArray.compactMap { dict in
                    guard let q = dict["q"] as? String,
                          let options = dict["options"] as? [String],
                          let correct = dict["correct"] as? String,
                          let explanation = dict["explanation"] as? String,
                          options.count == 4 else { return nil }
                    return QuizQuestion(q: q, options: options, correct: correct, explanation: explanation)
                }
            }
        }

        return nil
    }

    private static func extractBracedJSON(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }
}

// MARK: - Persisted Quiz Session

/// A completed quiz session saved to disk for the Learning Dashboard.
/// Stores the questions, answers, score, and metadata so users can retake
/// or review past quizzes from the home page.
struct PersistedQuizSession: Identifiable, Codable, Equatable {
    internal let id: String
    let topic: String
    let questions: [QuizQuestion]
    internal let selectedAnswers: [String: String]
    let score: Int
    let completedAt: Date
    let sourceSessionID: String?

    /// Number of questions in this quiz.
    var totalCount: Int { questions.count }

    /// Wrong answers with question + selected option for review.
    var wrongAnswers: [(question: QuizQuestion, selected: String)] {
        questions.compactMap { question in
            guard let selected = selectedAnswers[question.id],
                  selected != question.correct else { return nil }
            return (question, selected)
        }
    }

    /// Score as a percentage (0-100).
    var scorePercent: Int {
        guard totalCount > 0 else { return 0 }
        return Int(round(Double(score) / Double(totalCount) * 100))
    }

/// Human-readable score label (e.g. "4/5 · 80%").
    var scoreLabel: String {
        "\(score)/\(totalCount) · \(scorePercent)%"
    }

    internal init(questions: [QuizQuestion], topic: String, selectedAnswers: [String: String], score: Int, sourceSessionID: String?) {
        self.id = UUID().uuidString
        self.topic = topic
        self.questions = questions
        self.selectedAnswers = selectedAnswers
        self.score = score
        self.completedAt = Date()
        self.sourceSessionID = sourceSessionID
    }

    /// Decode tolerating BOTH key shapes for `selectedAnswers`: Swift
    /// encodes `[UUID: String]` as a FLAT ARRAY (`[key, value, key, value]`),
    /// not an object, so legacy quiz files on disk carry the array form. A
    /// naive `[String: String]` decode would throw and silently drop the
    /// user's saved quiz history.
    internal init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.topic = try c.decode(String.self, forKey: .topic)
        self.questions = try c.decode([QuizQuestion].self, forKey: .questions)
        self.score = try c.decode(Int.self, forKey: .score)
        self.completedAt = try c.decode(Date.self, forKey: .completedAt)
        self.sourceSessionID = try c.decodeIfPresent(String.self, forKey: .sourceSessionID)
        do {
            self.selectedAnswers = try c.decode([String: String].self, forKey: .selectedAnswers)
        } catch {
            // Expected branch for pre-migration files: [UUID: V] encodes as
            // a flat array, which the modern object decode rejects.
            let legacy = try c.decode([UUID: String].self, forKey: .selectedAnswers)
            self.selectedAnswers = Dictionary(
                uniqueKeysWithValues: legacy.map { ($0.key.uuidString, $0.value) })
        }
    }
}
