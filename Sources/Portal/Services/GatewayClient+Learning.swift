import Foundation

// MARK: - Learning RPC surface (learning.*)
//
// Gateway-persisted courses, decks, learner progress, and quiz attempts.
// List/get return nil on method-not-found (-32601) — the runtime probe
// convention shared with `artifactList()`, so `LearningStore` stays
// local-only against gateways that predate the surface.
//
// Content mutations are GRANULAR: one course shell / module / step / card
// batch per call, so nothing ever resends a parent document. Learner state
// (progress/SRS) is recorded as events the server folds with commutative
// rules; the client optimistic-updates and the fold reconciles.

/// Wire shape of one course as the gateway stores it. Translation to the
/// domain `Curriculum` lives in `LearningWire`.
internal struct LearningCourseWire {
    internal let id: String
    internal let title: String
    internal let summary: String
    internal let rev: Int
    internal let modules: [[String: AnyCodable]]
    internal let progress: [String: AnyCodable]

    internal static func from(
        _ d: [String: AnyCodable]?, progress: [String: AnyCodable]? = nil
    ) -> LearningCourseWire? {
        guard let d, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return LearningCourseWire(
            id: id,
            title: d["title"]?.stringValue ?? "",
            summary: d["summary"]?.stringValue ?? "",
            rev: d["rev"]?.intValue ?? 0,
            modules: d["modules"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? [],
            progress: progress ?? [:]
        )
    }
}

/// A course list row: id/title/rev/counts, no module bodies.
internal struct LearningCourseSummary {
    internal let id: String
    internal let title: String
    internal let rev: Int

    internal static func from(_ d: [String: AnyCodable]?) -> LearningCourseSummary? {
        guard let d, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return LearningCourseSummary(
            id: id,
            title: d["title"]?.stringValue ?? "",
            rev: d["rev"]?.intValue ?? 0
        )
    }
}

/// Wire shape of one deck plus its folded SRS map.
internal struct LearningDeckWire {
    internal let id: String
    internal let topic: String
    internal let rev: Int
    internal let cards: [[String: AnyCodable]]
    internal let srs: [String: AnyCodable]

    internal static func from(
        _ d: [String: AnyCodable]?, srs: [String: AnyCodable]? = nil
    ) -> LearningDeckWire? {
        guard let d, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return LearningDeckWire(
            id: id,
            topic: d["topic"]?.stringValue ?? "",
            rev: d["rev"]?.intValue ?? 0,
            cards: d["cards"]?.arrayValue?.compactMap { $0.dictionaryValue } ?? [],
            srs: srs ?? [:]
        )
    }
}

internal struct LearningDeckSummary {
    internal let id: String
    internal let topic: String
    internal let rev: Int

    internal static func from(_ d: [String: AnyCodable]?) -> LearningDeckSummary? {
        guard let d, let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return LearningDeckSummary(
            id: id,
            topic: d["topic"]?.stringValue ?? "",
            rev: d["rev"]?.intValue ?? 0
        )
    }
}

@MainActor
extension GatewayClient {

    private func learningRawCall(
        _ method: String, params: [String: AnyCodable] = [:]
    ) async throws -> JSONRPCResponse {
        if let override = learningCallOverrideForTesting {
            return try await override(method, params)
        }
        return try await call(method, params: params)
    }

    /// Shared error handling: nil result on method-not-found (probe), throw
    /// on real errors, result dict otherwise.
    private func learningCall(
        _ method: String, params: [String: AnyCodable] = [:]
    ) async throws -> [String: AnyCodable]? {
        let response = try await learningRawCall(method, params: params)
        if let error = response.error {
            if error.code == -32601 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        return response.result?.dictionaryValue ?? [:]
    }

    // MARK: Courses

    /// nil = gateway predates learning.* (the store's runtime probe).
    internal func learningCourseList() async throws -> [LearningCourseSummary]? {
        guard let result = try await learningCall("learning.course.list") else { return nil }
        let rows = result["courses"]?.arrayValue ?? []
        return rows.compactMap { LearningCourseSummary.from($0.dictionaryValue) }
    }

    internal func learningCourseGet(id: String) async throws -> LearningCourseWire? {
        let response = try await learningRawCall("learning.course.get", params: ["id": AnyCodable(id)])
        if let error = response.error {
            if error.code == -32601 || error.code == 4004 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        let result = response.result?.dictionaryValue
        return LearningCourseWire.from(
            result?["course"]?.dictionaryValue,
            progress: result?["progress"]?.dictionaryValue
        )
    }

    /// Create/update a course shell. Returns (id, rev) of the stored course.
    internal func learningCourseSet(
        id: String?, title: String, summary: String, sourceSessionID: String?
    ) async throws -> (id: String, rev: Int)? {
        var params: [String: AnyCodable] = [
            "title": AnyCodable(title),
            "summary": AnyCodable(summary),
            "updated_by": AnyCodable("app:\(SessionMetaSyncService.deviceID.prefix(8))"),
        ]
        if let id { params["id"] = AnyCodable(id) }
        if let sourceSessionID { params["source_session_id"] = AnyCodable(sourceSessionID) }
        guard let result = try await learningCall("learning.course.set", params: params),
              let course = result["course"]?.dictionaryValue,
              let storedID = course["id"]?.stringValue else { return nil }
        return (storedID, course["rev"]?.intValue ?? 0)
    }

    internal func learningCourseDelete(id: String) async throws {
        _ = try await learningCall("learning.course.delete", params: ["id": AnyCodable(id)])
    }

    /// Upsert one module. Returns (moduleID, courseRev).
    internal func learningModuleSet(
        courseID: String, moduleID: String?, title: String?, overview: String?, position: Int? = nil
    ) async throws -> (id: String, rev: Int)? {
        var params: [String: AnyCodable] = [
            "course_id": AnyCodable(courseID),
            "updated_by": AnyCodable("app:\(SessionMetaSyncService.deviceID.prefix(8))"),
        ]
        if let moduleID { params["id"] = AnyCodable(moduleID) }
        if let title { params["title"] = AnyCodable(title) }
        if let overview { params["overview"] = AnyCodable(overview) }
        if let position { params["position"] = AnyCodable(position) }
        guard let result = try await learningCall("learning.module.set", params: params),
              let module = result["module"]?.dictionaryValue,
              let id = module["id"]?.stringValue else { return nil }
        return (id, result["rev"]?.intValue ?? 0)
    }

    /// Upsert one step. `questions` is the wire array for quiz steps.
    internal func learningStepSet(
        courseID: String, moduleID: String, stepID: String?,
        title: String?, type: String?, markdown: String?,
        questions: [[String: Any]]?
    ) async throws -> (id: String, rev: Int)? {
        var params: [String: AnyCodable] = [
            "course_id": AnyCodable(courseID),
            "module_id": AnyCodable(moduleID),
            "updated_by": AnyCodable("app:\(SessionMetaSyncService.deviceID.prefix(8))"),
        ]
        if let stepID { params["id"] = AnyCodable(stepID) }
        if let title { params["title"] = AnyCodable(title) }
        if let type { params["type"] = AnyCodable(type) }
        if let markdown { params["markdown"] = AnyCodable(markdown) }
        if let questions { params["questions"] = AnyCodable(any: questions) }
        guard let result = try await learningCall("learning.step.set", params: params),
              let step = result["step"]?.dictionaryValue,
              let id = step["id"]?.stringValue else { return nil }
        return (id, result["rev"]?.intValue ?? 0)
    }

    // MARK: Decks

    internal func learningDeckList() async throws -> [LearningDeckSummary]? {
        guard let result = try await learningCall("learning.deck.list") else { return nil }
        let rows = result["decks"]?.arrayValue ?? []
        return rows.compactMap { LearningDeckSummary.from($0.dictionaryValue) }
    }

    internal func learningDeckGet(id: String) async throws -> LearningDeckWire? {
        let response = try await learningRawCall("learning.deck.get", params: ["id": AnyCodable(id)])
        if let error = response.error {
            if error.code == -32601 || error.code == 4004 { return nil }
            throw GatewayError.rpcError(JSONRPCError(code: error.code, message: error.message))
        }
        let result = response.result?.dictionaryValue
        return LearningDeckWire.from(
            result?["deck"]?.dictionaryValue,
            srs: result?["srs"]?.dictionaryValue
        )
    }

    internal func learningDeckSet(id: String?, topic: String) async throws -> (id: String, rev: Int)? {
        var params: [String: AnyCodable] = [
            "topic": AnyCodable(topic),
            "updated_by": AnyCodable("app:\(SessionMetaSyncService.deviceID.prefix(8))"),
        ]
        if let id { params["id"] = AnyCodable(id) }
        guard let result = try await learningCall("learning.deck.set", params: params),
              let deck = result["deck"]?.dictionaryValue,
              let storedID = deck["id"]?.stringValue else { return nil }
        return (storedID, deck["rev"]?.intValue ?? 0)
    }

    internal func learningDeckDelete(id: String) async throws {
        _ = try await learningCall("learning.deck.delete", params: ["id": AnyCodable(id)])
    }

    /// Batched card upsert. Returns the stored card ids in order.
    internal func learningCardSet(
        deckID: String, cards: [[String: Any]]
    ) async throws -> (cardIDs: [String], rev: Int)? {
        let params: [String: AnyCodable] = [
            "deck_id": AnyCodable(deckID),
            "cards": AnyCodable(any: cards),
            "updated_by": AnyCodable("app:\(SessionMetaSyncService.deviceID.prefix(8))"),
        ]
        guard let result = try await learningCall("learning.card.set", params: params) else { return nil }
        let ids = result["card_ids"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        return (ids, result["rev"]?.intValue ?? 0)
    }

    // MARK: Learner state (client-written, server-folded)

    /// Record a progress event. `at` is sent only when the client considers
    /// the event completing (lesson read; quiz attempt at/above threshold) —
    /// the server folds `completed_at` from the first stamped event.
    internal func learningProgressRecord(
        courseID: String, stepID: String, kind: String,
        scorePercent: Int?, at: Date?
    ) async throws {
        var params: [String: AnyCodable] = [
            "course_id": AnyCodable(courseID),
            "step_id": AnyCodable(stepID),
            "kind": AnyCodable(kind),
        ]
        if let scorePercent { params["score_percent"] = AnyCodable(scorePercent) }
        if let at {
            params["at"] = AnyCodable(ISO8601DateFormatter().string(from: at))
        }
        _ = try await learningCall("learning.progress.record", params: params)
    }

    /// Record one SRS review. `bootstrapState` carries a full local SM-2
    /// state dict, honored by the server only when it has none for the card
    /// (the migration import path).
    internal func learningReviewRecord(
        deckID: String, cardID: String, quality: Int,
        reviewedAt: Date, bootstrapState: [String: Any]? = nil
    ) async throws {
        var params: [String: AnyCodable] = [
            "deck_id": AnyCodable(deckID),
            "card_id": AnyCodable(cardID),
            "quality": AnyCodable(quality),
            "reviewed_at": AnyCodable(ISO8601DateFormatter().string(from: reviewedAt)),
        ]
        if let bootstrapState { params["state"] = AnyCodable(any: bootstrapState) }
        _ = try await learningCall("learning.review.record", params: params)
    }

    /// Append a finished quiz to the gateway's immutable attempt log.
    internal func learningAttemptRecord(_ attempt: [String: Any]) async throws {
        let params = attempt.mapValues { AnyCodable(any: $0) }
        _ = try await learningCall("learning.attempt.record", params: params)
    }
}
