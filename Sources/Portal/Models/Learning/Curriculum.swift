import Foundation

/// A structured course: ordered modules, each holding ordered steps that are
/// either a written lesson or a quiz. Unlike a standalone quiz or deck, a
/// curriculum tracks *per-step* progress so "where was I" and "how far in am I"
/// are answerable at every level.
///
/// Step content is stored **inline**, not referenced by id. That is deliberate:
/// `PersistedQuizSession` mints a fresh `UUID` on every save (there is no update
/// path in `QuizStore`), so a reference to a quiz would silently point at one
/// historical attempt while retakes landed in unrelated records. An
/// agent-authored curriculum *is* its content, so owning it outright also makes
/// dangling references impossible.
/// Ids are Strings, not UUIDs: course/module/step identity round-trips
/// through the gateway learning store, whose ids are server-minted strings
/// (`crs-`/`m-`/`s-` + hex8). Locally-minted entities use a UUID string —
/// the gateway id grammar accepts it verbatim, so pushing a local course up
/// needs no id translation.
internal struct Curriculum: Identifiable, Codable, Equatable {
    internal let id: String
    internal var title: String
    /// One-paragraph description of what the course covers.
    internal var summary: String
    internal var modules: [CurriculumModule]
    internal let created: Date
    /// Chat session this was generated from, when known.
    internal let sourceSessionID: String?
    /// Per-step progress, keyed by step id — mirrors how `FlashcardDeck` keys
    /// `srsStates` by card id.
    internal var progress: [String: CurriculumStepProgress]
    /// Gateway revision. 0 = local-only (never pushed) — the migration
    /// marker `LearningStore.pull()` uses, mirroring `LivingArtifact`.
    internal var rev: Int = 0

    internal init(
        title: String,
        summary: String,
        modules: [CurriculumModule],
        sourceSessionID: String? = nil,
        id: String = UUID().uuidString
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.modules = modules
        self.created = Date()
        self.sourceSessionID = sourceSessionID
        self.progress = [:]
    }

    /// Decode tolerating BOTH key shapes for `progress`: Swift encodes
    /// `[UUID: V]` as a FLAT ARRAY, not an object, so every course saved
    /// before the String-id migration carries the array form on disk. A
    /// naive `[String: V]` decode would throw — and `allCurricula()` drops
    /// files that fail to decode, which reads as the user's course history
    /// silently vanishing.
    internal init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.summary = try c.decode(String.self, forKey: .summary)
        self.modules = try c.decode([CurriculumModule].self, forKey: .modules)
        self.created = try c.decode(Date.self, forKey: .created)
        self.sourceSessionID = try c.decodeIfPresent(String.self, forKey: .sourceSessionID)
        self.rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
        do {
            self.progress = try c.decode([String: CurriculumStepProgress].self, forKey: .progress)
        } catch {
            // Expected branch for pre-migration files: [UUID: V] encodes as
            // a flat array, which the modern object decode rejects.
            let legacy = try c.decode([UUID: CurriculumStepProgress].self, forKey: .progress)
            self.progress = Dictionary(uniqueKeysWithValues: legacy.map {
                ($0.key.uuidString, $0.value)
            })
        }
    }
}

// MARK: - Module

/// A named group of steps — the unit a learner thinks of as "a chapter".
internal struct CurriculumModule: Identifiable, Codable, Equatable {
    internal let id: String
    internal let title: String
    /// Short framing shown above the module's steps. May be empty.
    internal let overview: String
    internal var steps: [CurriculumStep]

    internal init(title: String, overview: String, steps: [CurriculumStep], id: String = UUID().uuidString) {
        self.id = id
        self.title = title
        self.overview = overview
        self.steps = steps
    }
}

// MARK: - Step

/// One thing to do: read a lesson or take a quiz.
internal struct CurriculumStep: Identifiable, Codable, Equatable {
    internal let id: String
    internal let title: String
    internal let kind: CurriculumStepKind

    internal init(title: String, kind: CurriculumStepKind, id: String = UUID().uuidString) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    internal var isQuiz: Bool {
        if case .quiz = kind { return true }
        return false
    }

    /// SF Symbol for the step's type, used by the outline and step rows.
    internal var icon: String {
        switch kind {
        case .lesson: return "doc.text"
        case .quiz:   return "questionmark.circle"
        }
    }

    /// "Lesson" / "Quiz · 5 questions" — the row subtitle.
    internal var kindLabel: String {
        switch kind {
        case .lesson:
            return "Lesson"
        case .quiz(let questions):
            return "Quiz · \(questions.count) question\(questions.count == 1 ? "" : "s")"
        }
    }
}

/// Step payload. `Codable` is written by hand rather than synthesized so the
/// on-disk shape is a readable `{"type": "lesson", "markdown": "…"}` — a
/// persisted format outlives the enum's source order, and the synthesized form
/// encodes case names as nested keys that are awkward to migrate.
internal enum CurriculumStepKind: Equatable {
    /// Markdown body, rendered with the app's shared `MarkdownContentView`.
    case lesson(markdown: String)
    /// Inline questions, played through the existing `QuizViewModel`.
    case quiz(questions: [QuizQuestion])
}

extension CurriculumStepKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, markdown, questions
    }

    private enum Discriminator: String, Codable {
        case lesson, quiz
    }

    internal init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Discriminator.self, forKey: .type) {
        case .lesson:
            self = .lesson(markdown: try container.decode(String.self, forKey: .markdown))
        case .quiz:
            self = .quiz(questions: try container.decode([QuizQuestion].self, forKey: .questions))
        }
    }

    internal func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lesson(let markdown):
            try container.encode(Discriminator.lesson, forKey: .type)
            try container.encode(markdown, forKey: .markdown)
        case .quiz(let questions):
            try container.encode(Discriminator.quiz, forKey: .type)
            try container.encode(questions, forKey: .questions)
        }
    }
}

// MARK: - Progress

/// What the learner has done with one step.
internal struct CurriculumStepProgress: Codable, Equatable {
    /// When the step first counted as complete. Nil while incomplete.
    internal var completedAt: Date?
    /// Best quiz score as a percentage. Nil for lessons, and for quizzes never
    /// finished. Best-of rather than latest, so a retake can only help.
    internal var bestScorePercent: Int?
    /// How many times the step has been opened and finished.
    internal var attempts: Int

    internal init(completedAt: Date? = nil, bestScorePercent: Int? = nil, attempts: Int = 0) {
        self.completedAt = completedAt
        self.bestScorePercent = bestScorePercent
        self.attempts = attempts
    }
}

// MARK: - Completion & rollup

extension Curriculum {

    /// Score a quiz step must reach to count as passed.
    ///
    /// One threshold for the whole app on purpose: a quiz reports a percentage
    /// and a deck reports "learned" cards, and leaving "done" per-kind vague is
    /// how progress rules sprawl. 80% is the bar the results screen already
    /// treats as a good run (`LearningQuizCard.scoreColor`).
    internal static let passThreshold = 80

    /// Every step across every module, in course order.
    internal var orderedSteps: [CurriculumStep] {
        modules.flatMap(\.steps)
    }

    internal var totalSteps: Int {
        modules.reduce(0) { $0 + $1.steps.count }
    }

    internal func progress(for step: CurriculumStep) -> CurriculumStepProgress? {
        progress[step.id]
    }

    /// Whether a step counts as done: a lesson once marked read, a quiz once it
    /// has been passed at `passThreshold` or better.
    internal func isComplete(_ step: CurriculumStep) -> Bool {
        guard let record = progress[step.id] else { return false }
        switch step.kind {
        case .lesson:
            return record.completedAt != nil
        case .quiz:
            return (record.bestScorePercent ?? 0) >= Self.passThreshold
        }
    }

    /// A quiz that was finished but scored below the bar — distinct from "not
    /// started", and worth showing differently.
    internal func needsRetry(_ step: CurriculumStep) -> Bool {
        guard step.isQuiz, let record = progress[step.id] else { return false }
        return record.attempts > 0 && (record.bestScorePercent ?? 0) < Self.passThreshold
    }

    internal var completedCount: Int {
        orderedSteps.filter { isComplete($0) }.count
    }

    /// 0…1 across the whole course. Zero steps reads as zero, not as done.
    internal var progressFraction: Double {
        guard totalSteps > 0 else { return 0 }
        return Double(completedCount) / Double(totalSteps)
    }

    internal var isFinished: Bool {
        totalSteps > 0 && completedCount == totalSteps
    }

    /// The first step not yet complete, in course order — what "Continue" opens.
    /// Nil once the course is finished.
    internal var nextStep: CurriculumStep? {
        orderedSteps.first { !isComplete($0) }
    }

    /// Module containing a step, for headers and breadcrumbs.
    internal func module(containing step: CurriculumStep) -> CurriculumModule? {
        modules.first { $0.steps.contains(where: { $0.id == step.id }) }
    }

    internal func completedCount(in module: CurriculumModule) -> Int {
        module.steps.filter { isComplete($0) }.count
    }

    /// Average of every recorded quiz score, or nil before any quiz is taken.
    internal var averageQuizScore: Int? {
        let scores = orderedSteps.compactMap { progress[$0.id]?.bestScorePercent }
        guard !scores.isEmpty else { return nil }
        return Int(round(Double(scores.reduce(0, +)) / Double(scores.count)))
    }

    // MARK: Mutation

    /// Mark a lesson read. Idempotent — the first completion timestamp stands,
    /// so re-reading doesn't rewrite history.
    internal mutating func markLessonRead(stepID: String) {
        var record = progress[stepID] ?? CurriculumStepProgress()
        record.attempts += 1
        if record.completedAt == nil {
            record.completedAt = Date()
        }
        progress[stepID] = record
    }

    /// Record a finished quiz attempt. Keeps the best score, and stamps
    /// completion the first time the attempt clears `passThreshold`.
    internal mutating func recordQuizAttempt(stepID: String, scorePercent: Int) {
        var record = progress[stepID] ?? CurriculumStepProgress()
        record.attempts += 1
        record.bestScorePercent = max(record.bestScorePercent ?? 0, scorePercent)
        if record.completedAt == nil, scorePercent >= Self.passThreshold {
            record.completedAt = Date()
        }
        progress[stepID] = record
    }

    /// Clear all progress, keeping the content. Used by "Restart course".
    internal mutating func resetProgress() {
        progress = [:]
    }
}

// MARK: - Agent JSON Parsing

/// Wire shape for an agent-authored curriculum. Kept separate from the domain
/// type — flat, id-free, and forgiving — because a model emits prose JSON, not
/// our persisted format. Mirrors `QuizResponse` / `FlashcardResponse`.
internal struct CurriculumResponse: Codable {
    internal let curriculum: RawCurriculum

    internal struct RawCurriculum: Codable {
        internal let title: String
        internal let summary: String?
        internal let modules: [RawModule]
    }

    internal struct RawModule: Codable {
        internal let title: String
        internal let overview: String?
        internal let steps: [RawStep]
    }

    internal struct RawStep: Codable {
        internal let type: String
        internal let title: String
        /// Lesson body. Also accepted under `content` by the lenient parser.
        internal let content: String?
        internal let questions: [QuizResponse.QuizQuestionRaw]?
    }
}

extension CurriculumResponse {

    /// Parse a curriculum out of an agent response, tolerating markdown fences
    /// and stray prose around the JSON. Returns nil unless the result has at
    /// least one module with at least one usable step — a half-parsed course is
    /// worse than none, since it would persist as a broken outline.
    internal static func extract(from text: String) -> Curriculum? {
        for candidate in Self.jsonCandidates(in: text) {
            guard let data = candidate.data(using: .utf8) else { continue }

            if let course = Self.strict(from: data) {
                return course
            }

            if let course = Self.lenient(from: data) {
                return course
            }
        }
        return nil
    }

    /// Strict decode of one candidate slice. A decode failure is not an error to
    /// report — most candidates are prose that merely *contains* JSON — so it's
    /// handled as a branch: fall through to the lenient parser, then to the next
    /// candidate.
    private static func strict(from data: Data) -> Curriculum? {
        do {
            let decoded = try JSONDecoder().decode(CurriculumResponse.self, from: data)
            return Self.build(from: decoded.curriculum)
        } catch {
            return nil
        }
    }

    /// Progressively less-strict slices of the response worth attempting.
    private static func jsonCandidates(in text: String) -> [String] {
        var candidates: [String] = []

        if let fenced = Self.fencedBlock(in: text) {
            candidates.append(fenced)
        }
        candidates.append(text)
        if let braced = Self.bracedJSON(in: text) {
            candidates.append(braced)
        }
        return candidates
    }

    private static func fencedBlock(in text: String) -> String? {
        for opener in ["```json", "```"] {
            guard let open = text.range(of: opener) else { continue }
            guard let close = text[open.upperBound...].range(of: "```") else { continue }
            return String(text[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func bracedJSON(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              start < end else { return nil }
        return String(text[start...end])
    }

    /// Build the domain type, dropping steps that carry no usable payload.
    private static func build(from raw: RawCurriculum) -> Curriculum? {
        let modules: [CurriculumModule] = raw.modules.compactMap { rawModule in
            let steps = rawModule.steps.compactMap(Self.step(from:))
            guard !steps.isEmpty else { return nil }
            return CurriculumModule(
                title: rawModule.title,
                overview: rawModule.overview ?? "",
                steps: steps
            )
        }
        guard !modules.isEmpty else { return nil }

        return Curriculum(
            title: raw.title,
            summary: raw.summary ?? "",
            modules: modules
        )
    }

    private static func step(from raw: RawStep) -> CurriculumStep? {
        switch raw.type.lowercased() {
        case "quiz":
            let questions = (raw.questions ?? []).map { $0.toQuizQuestion() }
            guard !questions.isEmpty else { return nil }
            return CurriculumStep(title: raw.title, kind: .quiz(questions: questions))
        case "lesson":
            guard let body = raw.content, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return CurriculumStep(title: raw.title, kind: .lesson(markdown: body))
        default:
            return nil
        }
    }

    // MARK: Lenient path

    /// Hand-rolled parse for responses the strict decoder rejects — a missing
    /// `summary`, a lesson body under `markdown`/`body` instead of `content`, a
    /// step type in title case. Same "must yield real steps" contract.
    private static func lenient(from data: Data) -> Curriculum? {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Same reasoning as `strict(from:)`: a non-JSON candidate is the
            // expected case, not a failure worth logging.
            return nil
        }
        guard let root = parsed as? [String: Any] else { return nil }
        // Accept both `{"curriculum": {...}}` and a bare course object.
        let course = (root["curriculum"] as? [String: Any]) ?? root
        guard let title = course["title"] as? String,
              let rawModules = course["modules"] as? [[String: Any]] else { return nil }

        let modules: [CurriculumModule] = rawModules.compactMap { rawModule in
            guard let moduleTitle = rawModule["title"] as? String,
                  let rawSteps = rawModule["steps"] as? [[String: Any]] else { return nil }
            let steps = rawSteps.compactMap(Self.lenientStep(from:))
            guard !steps.isEmpty else { return nil }
            return CurriculumModule(
                title: moduleTitle,
                overview: rawModule["overview"] as? String ?? "",
                steps: steps
            )
        }
        guard !modules.isEmpty else { return nil }

        return Curriculum(
            title: title,
            summary: course["summary"] as? String ?? "",
            modules: modules
        )
    }

    private static func lenientStep(from raw: [String: Any]) -> CurriculumStep? {
        guard let title = raw["title"] as? String else { return nil }
        let type = (raw["type"] as? String ?? "").lowercased()

        if type == "quiz" || raw["questions"] != nil {
            guard let rawQuestions = raw["questions"] as? [[String: Any]] else { return nil }
            let questions: [QuizQuestion] = rawQuestions.compactMap { item in
                guard let prompt = item["q"] as? String ?? item["question"] as? String,
                      let options = item["options"] as? [String],
                      let correct = item["correct"] as? String else { return nil }
                return QuizQuestion(
                    q: prompt,
                    options: options,
                    correct: correct,
                    explanation: item["explanation"] as? String ?? ""
                )
            }
            guard !questions.isEmpty else { return nil }
            return CurriculumStep(title: title, kind: .quiz(questions: questions))
        }

        let body = raw["content"] as? String
            ?? raw["markdown"] as? String
            ?? raw["body"] as? String
        guard let body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return CurriculumStep(title: title, kind: .lesson(markdown: body))
    }
}
