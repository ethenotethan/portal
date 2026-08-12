import Combine
import Foundation

/// The slice of the gateway that `ArtifactStore` depends on — the artifact.*
/// sync surface plus the artifact.action.* intent surface, and the event
/// stream it subscribes to for live `artifact.changed` pushes.
///
/// Extracting this narrow protocol (rather than one giant `GatewayClientProtocol`)
/// follows the codebase's existing capability-protocol idiom (`WikiSource`,
/// `AgentBackend`, …): the store depends on the capability, `GatewayClient`
/// conforms for free (every method already exists with these signatures), and
/// tests inject a `FakeArtifactGateway` to drive the invocation state machine
/// without a live socket. Class-bound because the store holds `client` weakly
/// and compares it by identity (`!==`) in `setClient`. `@MainActor`-isolated
/// and `Sendable` to match the concrete `GatewayClient` (a `@MainActor final
/// class`), so the existential can be held across the store's `Task`s exactly
/// as the concrete type was.
@MainActor
internal protocol ArtifactGateway: AnyObject, Sendable {
    /// Live gateway events; the store filters for `.artifactChanged`.
    var eventStream: PassthroughSubject<(GatewayEvent, String?), Never> { get }

    // artifact.* sync surface
    func artifactGet(id: String) async throws -> LivingArtifact?
    func artifactList() async throws -> [LivingArtifact]?
    func artifactSet(
        id: String, kind: String, content: String, title: String?, replace: Bool
    ) async throws -> LivingArtifact?
    func artifactDelete(id: String) async throws

    // artifact.action.* intent surface
    func artifactActionInvoke(
        artifactID: String,
        artifactRev: Int,
        bindingID: String,
        entityRef: String,
        idempotencyKey: String
    ) async throws -> ArtifactActionInvokeResult?
    func artifactActionConfirm(
        artifactID: String, challenge: String
    ) async throws -> ArtifactActionInvokeResult?
    func artifactActionLog(
        artifactID: String, bindingID: String?, limit: Int
    ) async throws -> [[String: AnyCodable]]?
}

/// Convenience overloads matching the defaulted call sites in `ArtifactStore`.
/// Protocol requirements can't declare default arguments, so these shorter
/// arities keep the store's calls (`artifactSet(…, title:)` without `replace`,
/// `artifactActionLog(artifactID:)`) untouched while the requirement itself
/// stays fully explicit for conformers. Their signatures differ from the
/// requirements (fewer parameters), so there's no redeclaration clash.
internal extension ArtifactGateway {
    func artifactSet(
        id: String, kind: String, content: String, title: String? = nil
    ) async throws -> LivingArtifact? {
        try await artifactSet(id: id, kind: kind, content: content, title: title, replace: false)
    }

    func artifactActionLog(
        artifactID: String, bindingID: String? = nil
    ) async throws -> [[String: AnyCodable]]? {
        try await artifactActionLog(artifactID: artifactID, bindingID: bindingID, limit: 50)
    }
}

/// `GatewayClient` already implements every member with these exact
/// signatures, so conformance is declaration-only.
extension GatewayClient: ArtifactGateway {}

/// The slice of the gateway that `LearningStore` depends on — the learning.*
/// sync surface plus the event stream for live `learning.changed` pushes.
/// Same idiom and rationale as `ArtifactGateway` above.
@MainActor
internal protocol LearningGateway: AnyObject, Sendable {
    /// Live gateway events; the store filters for `.learningChanged`.
    var eventStream: PassthroughSubject<(GatewayEvent, String?), Never> { get }

    // Courses
    func learningCourseList() async throws -> [LearningCourseSummary]?
    func learningCourseGet(id: String) async throws -> LearningCourseWire?
    func learningCourseSet(
        id: String?, title: String, summary: String, sourceSessionID: String?
    ) async throws -> (id: String, rev: Int)?
    func learningCourseDelete(id: String) async throws
    func learningModuleSet(
        courseID: String, moduleID: String?, title: String?, overview: String?, position: Int?
    ) async throws -> (id: String, rev: Int)?
    func learningStepSet(
        courseID: String, moduleID: String, stepID: String?,
        title: String?, type: String?, markdown: String?,
        questions: [[String: Any]]?
    ) async throws -> (id: String, rev: Int)?

    // Decks
    func learningDeckList() async throws -> [LearningDeckSummary]?
    func learningDeckGet(id: String) async throws -> LearningDeckWire?
    func learningDeckSet(id: String?, topic: String) async throws -> (id: String, rev: Int)?
    func learningDeckDelete(id: String) async throws
    func learningCardSet(
        deckID: String, cards: [[String: Any]]
    ) async throws -> (cardIDs: [String], rev: Int)?

    // Learner state (client-written, server-folded)
    func learningProgressRecord(
        courseID: String, stepID: String, kind: String, scorePercent: Int?, at: Date?
    ) async throws
    func learningReviewRecord(
        deckID: String, cardID: String, quality: Int,
        reviewedAt: Date, bootstrapState: [String: Any]?
    ) async throws
    func learningAttemptRecord(_ attempt: [String: Any]) async throws
}

/// `GatewayClient` already implements every member (GatewayClient+Learning),
/// so conformance is declaration-only.
extension GatewayClient: LearningGateway {}

/// Adopted by any type that tracks LLM token consumption and cost.
/// Canonical field names follow the Anthropic API convention (input/output,
/// not prompt/completion). `totalTokens` is a derived convenience; conforming
/// types may store it or compute it — the protocol only requires a getter.
internal protocol TokenAccountable {
    var inputTokens: Int? { get }
    var outputTokens: Int? { get }
    var costUSD: Double? { get }
    var totalTokens: Int? { get }
}

/// Adopted by any type that represents a single tool invocation record.
/// `context` is the preview text surfaced at tool.start (what the tool is
/// about to do); `summary` is the human-readable result from tool.complete.
internal protocol ToolCallRepresentable: Identifiable where ID == String {
    var id: String { get }
    var name: String { get }
    var context: String? { get }
    var summary: String? { get }
    var durationSeconds: Double? { get }
    var isComplete: Bool { get }
}
