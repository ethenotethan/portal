import Testing
import Foundation
@testable import HermesNative

/// Deterministic shared-entity detection: high-precision patterns, grouped by
/// target, only surfaced when >1 bar touches them. No model, no inference.
@Suite("Shared entity extractor")
internal struct SharedEntityExtractorTests {

    private func node(_ id: String, _ context: String, name: String = "terminal") -> ThoughtGraphNode {
        ThoughtGraphNode(id: id, name: name, context: context, isComplete: true, startedAt: Date())
    }

    @Test("three calls to the same pod become one shared entity with all node ids")
    internal func groupsPodTouches() {
        let entities = SharedEntityExtractor.extract(from: [
            node("t1", "kubectl get pod/api-server"),
            node("t2", "kubectl describe pod api-server"),
            node("t3", "kubectl delete pod/api-server"),
        ])
        #expect(entities.count == 1)
        let pod = try? #require(entities.first)
        #expect(pod?.kind == .k8sPod)
        #expect(pod?.label == "api-server")
        #expect(Set(pod?.nodeIDs ?? []) == ["t1", "t2", "t3"])
    }

    @Test("an entity touched by only one bar is not surfaced (nothing to connect)")
    internal func skipsSingleTouch() {
        let entities = SharedEntityExtractor.extract(from: [
            node("t1", "kubectl get pod/lonely"),
            node("t2", "read a file"),
        ])
        #expect(entities.isEmpty)
    }

    @Test("shared http host across calls is detected")
    internal func groupsHost() {
        let entities = SharedEntityExtractor.extract(from: [
            node("t1", "curl https://api.example.com/v1/users"),
            node("t2", "curl https://api.example.com/v1/orders"),
        ])
        let host = entities.first { $0.kind == .host }
        #expect(host?.label == "api.example.com")
        #expect(host?.nodeIDs.count == 2)
    }

    @Test("distinct resources are distinct entities")
    internal func distinctResources() {
        let entities = SharedEntityExtractor.extract(from: [
            node("t1", "kubectl get svc/gateway"),
            node("t2", "kubectl get svc/gateway"),
            node("t3", "kubectl get svc/worker"),
            node("t4", "kubectl get svc/worker"),
        ])
        #expect(entities.count == 2)
        #expect(Set(entities.map(\.label)) == ["gateway", "worker"])
    }

    @Test("prose with no entity references yields nothing")
    internal func noFalsePositives() {
        let entities = SharedEntityExtractor.extract(from: [
            node("t1", "thinking about the plan"),
            node("t2", "considering options"),
        ])
        #expect(entities.isEmpty)
    }

    @Test("one node mentioning an entity twice counts as a single touch")
    internal func dedupWithinNode() {
        let entities = SharedEntityExtractor.extract(from: [
            node("t1", "kubectl get pod/api pod/api again"),
        ])
        // Only one node touches it → not shared → not surfaced.
        #expect(entities.isEmpty)
    }
}
