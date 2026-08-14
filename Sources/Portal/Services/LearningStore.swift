import Combine
import Foundation
import os

private let log = Logger(subsystem: "com.ethenotethan.Portal", category: "LearningStore")

/// The Learning surface's single owner: courses, quizzes, and flashcard
/// decks, held in memory (`@Published`), cached to the SAME disk files the
/// old per-type stores used, and synced to the gateway's learning.* surface
/// when one is connected.
///
/// Three layers, mirroring `ArtifactStore`:
///  1. `@Published` dicts — what views observe.
///  2. Disk cache — the pre-existing `portal/curricula`, `portal/quizzes`,
///     `portal/srs-decks` directories, unchanged format, so this store
///     adopts years of local data with no file migration.
///  3. Gateway — source of truth when reachable. Runtime-probed
///     (`learningCourseList()` nil = old gateway → stay local-only), so the
///     app keeps working fully offline and against old backends.
///
/// Ownership rules the sync engine encodes:
///  - COURSE/DECK CONTENT is rev'd; a remote rev higher than local wins,
///    stale events are dropped. Content pushes are GRANULAR (course shell +
///    per-module + per-step), never a whole-document resend.
///  - LEARNER STATE (progress, SRS) is written optimistically here and
///    recorded to the gateway as events the server folds with commutative
///    rules — identical local fold, so both sides converge without a rev.
///  - QUIZ ATTEMPTS are append-only history, mirrored up fire-and-forget.
@MainActor
internal final class LearningStore: ObservableObject {

    internal static let shared = LearningStore()

    @Published internal private(set) var courses: [String: Curriculum] = [:]
    @Published internal private(set) var decks: [String: FlashcardDeck] = [:]
    @Published internal private(set) var attempts: [PersistedQuizSession] = []

    /// Whether the connected gateway supports learning.*. Genuinely
    /// three-state — unknown until the first probe answers — and the states
    /// behave differently (`unknown` lets pull() try; `unsupported` stops
    /// everything), so an enum rather than the `Bool?` trap.
    private enum SyncAvailability { case unknown, available, unsupported }

    private weak var client: (any LearningGateway)?
    private var sync: SyncAvailability = .unknown
    private var eventCancellable: AnyCancellable?

    /// The legacy per-type stores, demoted to private disk backends. Their
    /// directories and formats are untouched — existing user data loads as-is
    /// (with the String-id decode shims on the models).
    private let curriculumDisk: CurriculumStore
    private let quizDisk: QuizStore
    private let srsDisk: SRSStore

    /// Whether content saves may schedule an upstream push. False for the
    /// SHARED singleton in a test process — same guard as ArtifactStore: unit
    /// tests share it, and an unguarded save would schedule a REAL gateway
    /// push when a client is wired, leaking test entities into the production
    /// store. True for test-constructed instances, whose only clients are the
    /// fakes the test injected — which is precisely how the push paths get
    /// their coverage.
    private let allowsUpstreamPush: Bool

    private init() {
        curriculumDisk = CurriculumStore()
        quizDisk = QuizStore.shared
        srsDisk = SRSStore.shared
        allowsUpstreamPush = !ProcessInfo.isTestProcess
        loadFromDisk()
    }

    /// Test initializer: fully isolated disk directories, no gateway.
    internal init(curriculumDirectory: URL) {
        curriculumDisk = CurriculumStore(directory: curriculumDirectory)
        quizDisk = QuizStore(directory: curriculumDirectory.appendingPathComponent("quizzes"))
        srsDisk = SRSStore(directory: curriculumDirectory.appendingPathComponent("decks"))
        allowsUpstreamPush = true
        loadFromDisk()
    }

    private func loadFromDisk() {
        courses = Dictionary(uniqueKeysWithValues: curriculumDisk.allCurricula().map { ($0.id, $0) })
        decks = Dictionary(uniqueKeysWithValues: srsDisk.allDecks().map { ($0.id, $0) })
        attempts = quizDisk.allQuizzes()
    }

    // MARK: - Read (views observe these)

    internal var sortedCourses: [Curriculum] {
        courses.values.sorted { $0.created > $1.created }
    }

    internal var sortedDecks: [FlashcardDeck] {
        decks.values.sorted { $0.created > $1.created }
    }

    internal func course(id: String) -> Curriculum? { courses[id] }

    // MARK: - Course content

    /// Upsert a course locally and push it up granularly. The one entry
    /// point for both a fresh envelope-parsed course and progress-bearing
    /// saves from the player.
    internal func saveCourse(_ course: Curriculum) {
        courses[course.id] = course
        curriculumDisk.save(course)
        pushCourse(course)
    }

    /// Run a fire-and-forget gateway record, logging failures. Learner-state
    /// records are best-effort by design: the local fold already applied, and
    /// the next pull/event reconciles — but the failure must be visible.
    private func recordUpstream(_ what: String, _ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                log.info("\(what) record failed: \(error.localizedDescription)")
            }
        }
    }

    internal func deleteCourse(id: String) {
        courses.removeValue(forKey: id)
        curriculumDisk.delete(id: id)
        guard let client, sync == .available else { return }
        recordUpstream("course delete") { try await client.learningCourseDelete(id: id) }
    }

    // MARK: - Learner state (optimistic local fold + gateway event)

    /// Mark a lesson read: fold locally (same rules the server applies),
    /// persist the cache, and record the event upstream.
    internal func recordLessonRead(courseID: String, stepID: String) {
        guard var course = courses[courseID] else { return }
        course.markLessonRead(stepID: stepID)
        courses[courseID] = course
        curriculumDisk.save(course)
        guard let client, sync == .available else { return }
        recordUpstream("lesson progress") {
            try await client.learningProgressRecord(
                courseID: courseID, stepID: stepID, kind: "lesson_read",
                scorePercent: nil, at: Date()
            )
        }
    }

    /// Record a course-quiz attempt. `at` is stamped only on a passing
    /// attempt — the server folds `completed_at` from the first stamp, so
    /// sending it unconditionally would complete failed steps.
    internal func recordQuizAttempt(courseID: String, stepID: String, scorePercent: Int) {
        guard var course = courses[courseID] else { return }
        course.recordQuizAttempt(stepID: stepID, scorePercent: scorePercent)
        courses[courseID] = course
        curriculumDisk.save(course)
        guard let client, sync == .available else { return }
        let passed = scorePercent >= Curriculum.passThreshold
        recordUpstream("quiz progress") {
            try await client.learningProgressRecord(
                courseID: courseID, stepID: stepID, kind: "quiz_attempt",
                scorePercent: scorePercent, at: passed ? Date() : nil
            )
        }
    }

    /// Restart a course: local-only by design. The gateway's fold rules are
    /// deliberately monotonic (first stamp wins), so a reset is a client
    /// presentation choice, not an upstream history rewrite.
    internal func resetCourseProgress(id: String) {
        guard var course = courses[id] else { return }
        course.resetProgress()
        courses[id] = course
        curriculumDisk.save(course)
    }

    // MARK: - Decks

    /// Save a deck after a review session: persist locally and record each
    /// newly-graded review upstream. Graded cards are found by DIFFING the
    /// stored deck's SRS states (reviewCount grew ⇒ graded this session) —
    /// callers don't thread grade lists through the view layers, and the
    /// diff can't invent reviews the local SM-2 didn't apply.
    internal func saveDeck(_ deck: FlashcardDeck) {
        let previous = decks[deck.id]
        decks[deck.id] = deck
        srsDisk.saveDeck(deck)
        pushDeckIfNew(deck)
        guard let client, sync == .available, deck.rev > 0 else { return }
        let graded = deck.srsStates.filter { cardID, state in
            state.reviewCount > (previous?.srsStates[cardID]?.reviewCount ?? 0)
        }
        guard !graded.isEmpty else { return }
        recordUpstream("SRS reviews") {
            for (cardID, state) in graded {
                try await client.learningReviewRecord(
                    deckID: deck.id, cardID: cardID, quality: state.lastQuality,
                    reviewedAt: state.lastReviewedAt ?? Date(), bootstrapState: nil
                )
            }
        }
    }

    internal func deleteDeck(id: String) {
        decks.removeValue(forKey: id)
        srsDisk.deleteDeck(id: id)
        guard let client, sync == .available else { return }
        recordUpstream("deck delete") { try await client.learningDeckDelete(id: id) }
    }

    // MARK: - Quiz attempts (append-only)

    internal func recordAttempt(_ session: PersistedQuizSession) {
        attempts.insert(session, at: 0)
        quizDisk.saveQuiz(session)
        guard let client, sync == .available else { return }
        var wire: [String: Any] = [
            "topic": session.topic,
            "score": session.score,
            "total": session.totalCount,
            "completed_at": ISO8601DateFormatter().string(from: session.completedAt),
        ]
        if let source = session.sourceSessionID { wire["source_session_id"] = source }
        recordUpstream("attempt") { try await client.learningAttemptRecord(wire) }
    }

    internal func deleteAttempt(id: String) {
        attempts.removeAll { $0.id == id }
        quizDisk.deleteQuiz(id: id)
        // Attempts are immutable history on the gateway — local delete is a
        // presentation choice, mirroring how the ledger is never rewritten.
    }

    // MARK: - Gateway sync

    /// Inject a gateway for tests WITHOUT `setClient`'s side effects.
    internal func injectClientForTesting(_ client: any LearningGateway) {
        self.client = client
        sync = .available
    }

    internal func setClient(_ client: any LearningGateway) {
        guard self.client !== client else { return }
        self.client = client
        sync = .unknown
        eventCancellable = client.eventStream
            .receive(on: RunLoop.main)
            .sink { [weak self] event, _ in
                guard case .learningChanged(let entity, let id, let rev, let deleted) = event else { return }
                self?.applyRemoteChange(entity: entity, id: id, rev: rev, deleted: deleted)
            }
        Task { await pull() }
    }

    /// A gateway-side mutation happened (agent tool, another device).
    /// Refetch the entity so open panes update live. `progress` events carry
    /// the parent course/deck id and always refetch — folds have no rev.
    private func applyRemoteChange(entity: String, id: String, rev: Int, deleted: Bool) {
        switch entity {
        case "course", "progress":
            if deleted {
                if courses.removeValue(forKey: id) != nil { curriculumDisk.delete(id: id) }
                return
            }
            // Rev guard applies only to content events; progress events
            // (rev 0) refetch unconditionally — the fold is idempotent.
            if entity == "course", let current = courses[id], rev > 0, current.rev >= rev {
                // Also our own push echo. Progress piggybacked on the fetch
                // keeps the guard safe: our optimistic fold already applied.
                return
            }
            refetchCourse(id: id)
            if entity == "progress", decks[id] != nil { refetchDeck(id: id) }
        case "deck":
            if deleted {
                if decks.removeValue(forKey: id) != nil { srsDisk.deleteDeck(id: id) }
                return
            }
            if let current = decks[id], rev > 0, current.rev >= rev { return }
            refetchDeck(id: id)
        default:
            break  // "attempt" events don't need a refetch — append-only.
        }
    }

    private func refetchCourse(id: String) {
        guard let client else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let wire = try await client.learningCourseGet(id: id) else { return }
                let fresh = LearningWire.curriculum(from: wire)
                if let current = self.courses[id], current.rev > fresh.rev { return }
                self.courses[id] = fresh
                self.curriculumDisk.save(fresh)
            } catch {
                log.info("course refetch failed: \(error.localizedDescription)")
            }
        }
    }

    private func refetchDeck(id: String) {
        guard let client else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let wire = try await client.learningDeckGet(id: id) else { return }
                let fresh = LearningWire.deck(from: wire)
                if let current = self.decks[id], current.rev > fresh.rev { return }
                self.decks[id] = fresh
                self.srsDisk.saveDeck(fresh)
            } catch {
                log.info("deck refetch failed: \(error.localizedDescription)")
            }
        }
    }

    /// Full resync. Gateway list is the source of truth; local-only entities
    /// (rev == 0: created offline or before the gateway had the surface) are
    /// pushed up GRANULARLY — this is the migration, run once per entity.
    /// nil list = old gateway → stay local-only forever this session.
    internal func pull() async {
        guard let client, sync != .unsupported else { return }
        do {
            guard let remoteCourses = try await client.learningCourseList() else {
                sync = .unsupported
                log.info("learning sync unavailable (gateway predates learning.*)")
                return
            }
            sync = .available

            let remoteCourseIDs = Set(remoteCourses.map(\.id))
            for summary in remoteCourses {
                let local = courses[summary.id]
                if local == nil || summary.rev > (local?.rev ?? 0) {
                    if let wire = try await client.learningCourseGet(id: summary.id) {
                        let fresh = LearningWire.curriculum(from: wire)
                        courses[summary.id] = fresh
                        curriculumDisk.save(fresh)
                    }
                }
            }
            for (id, local) in courses where !remoteCourseIDs.contains(id) && local.rev == 0 {
                await migrateCourseUp(local)
            }

            if let remoteDecks = try await client.learningDeckList() {
                let remoteDeckIDs = Set(remoteDecks.map(\.id))
                for summary in remoteDecks {
                    let local = decks[summary.id]
                    if local == nil || summary.rev > (local?.rev ?? 0) {
                        if let wire = try await client.learningDeckGet(id: summary.id) {
                            let fresh = LearningWire.deck(from: wire)
                            decks[summary.id] = fresh
                            srsDisk.saveDeck(fresh)
                        }
                    }
                }
                for (id, local) in decks where !remoteDeckIDs.contains(id) && local.rev == 0 {
                    await migrateDeckUp(local)
                }
            }
        } catch {
            log.info("learning pull failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Granular push (content)

    /// Push a course's content up piece by piece: shell, then each module,
    /// then each step — the same calls the agent tool makes, so the gateway
    /// never receives (and we never construct) a whole-course blob.
    private func pushCourse(_ course: Curriculum) {
        guard let client, sync == .available, allowsUpstreamPush else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let stored = try await client.learningCourseSet(
                    id: course.id, title: course.title, summary: course.summary,
                    sourceSessionID: course.sourceSessionID
                ) else { return }
                for module in course.modules {
                    _ = try await client.learningModuleSet(
                        courseID: course.id, moduleID: module.id,
                        title: module.title, overview: module.overview, position: nil
                    )
                    for step in module.steps {
                        let fields = LearningWire.stepFields(step)
                        _ = try await client.learningStepSet(
                            courseID: course.id, moduleID: module.id, stepID: step.id,
                            title: step.title, type: fields.type,
                            markdown: fields.markdown, questions: fields.questions
                        )
                    }
                }
                // Adopt the server's final rev so subsequent events guard right.
                if let wire = try await client.learningCourseGet(id: course.id) {
                    var adopted = LearningWire.curriculum(from: wire)
                    // Keep richer local progress over a just-created server copy.
                    if adopted.progress.isEmpty { adopted.progress = course.progress }
                    self.courses[course.id] = adopted
                    self.curriculumDisk.save(adopted)
                } else {
                    var bumped = course
                    bumped.rev = stored.rev
                    self.courses[course.id] = bumped
                    self.curriculumDisk.save(bumped)
                }
            } catch {
                log.info("course push failed: \(error.localizedDescription)")
            }
        }
    }

    /// Migration: push a local-only course up including its progress replay.
    private func migrateCourseUp(_ course: Curriculum) async {
        guard let client else { return }
        do {
            guard try await client.learningCourseSet(
                id: course.id, title: course.title, summary: course.summary,
                sourceSessionID: course.sourceSessionID
            ) != nil else { return }
            for module in course.modules {
                _ = try await client.learningModuleSet(
                    courseID: course.id, moduleID: module.id,
                    title: module.title, overview: module.overview, position: nil
                )
                for step in module.steps {
                    let fields = LearningWire.stepFields(step)
                    _ = try await client.learningStepSet(
                        courseID: course.id, moduleID: module.id, stepID: step.id,
                        title: step.title, type: fields.type,
                        markdown: fields.markdown, questions: fields.questions
                    )
                }
            }
            // Replay local progress as fold events. Lesson completions and
            // best scores replay exactly; attempt COUNTS collapse to one
            // event per step (the fold increments per event) — an accepted
            // lossy corner, per-step counts are cosmetic.
            for (stepID, record) in course.progress {
                if let score = record.bestScorePercent {
                    try await client.learningProgressRecord(
                        courseID: course.id, stepID: stepID, kind: "quiz_attempt",
                        scorePercent: score, at: record.completedAt
                    )
                } else if record.completedAt != nil {
                    try await client.learningProgressRecord(
                        courseID: course.id, stepID: stepID, kind: "lesson_read",
                        scorePercent: nil, at: record.completedAt
                    )
                }
            }
            if let wire = try await client.learningCourseGet(id: course.id) {
                let adopted = LearningWire.curriculum(from: wire)
                courses[course.id] = adopted
                curriculumDisk.save(adopted)
            }
            log.info("migrated local course \(course.id) to gateway")
        } catch {
            log.info("course migration failed: \(error.localizedDescription)")
        }
    }

    /// Push a brand-new deck's content (rev 0 = never pushed). Reviewed
    /// decks that already live server-side sync per-review instead.
    private func pushDeckIfNew(_ deck: FlashcardDeck) {
        guard deck.rev == 0, let client, sync == .available, allowsUpstreamPush else { return }
        Task { [weak self] in
            await self?.migrateDeckUp(deck)
            _ = client  // captured for lifetime; migrate uses self.client
        }
    }

    /// Migration: deck shell + batched cards + SRS bootstrap import.
    private func migrateDeckUp(_ deck: FlashcardDeck) async {
        guard let client else { return }
        do {
            guard try await client.learningDeckSet(id: deck.id, topic: deck.topic) != nil,
                  !deck.cards.isEmpty else { return }
            _ = try await client.learningCardSet(
                deckID: deck.id, cards: deck.cards.map(LearningWire.wireCard)
            )
            // Bootstrap-import reviewed cards' SM-2 history: honored only
            // when the server has no state for the card, so this can never
            // clobber another device's live schedule.
            for (cardID, state) in deck.srsStates where state.reviewCount > 0 {
                try await client.learningReviewRecord(
                    deckID: deck.id, cardID: cardID, quality: state.lastQuality,
                    reviewedAt: state.lastReviewedAt ?? Date(),
                    bootstrapState: LearningWire.wireSRSState(state)
                )
            }
            if let wire = try await client.learningDeckGet(id: deck.id) {
                var adopted = LearningWire.deck(from: wire)
                // Keep local SRS for cards the bootstrap didn't cover.
                for (cardID, state) in deck.srsStates where adopted.srsStates[cardID]?.reviewCount == 0 {
                    if state.reviewCount > 0 { adopted.srsStates[cardID] = state }
                }
                decks[deck.id] = adopted
                srsDisk.saveDeck(adopted)
            }
            log.info("migrated local deck \(deck.id) to gateway")
        } catch {
            log.info("deck migration failed: \(error.localizedDescription)")
        }
    }
}
