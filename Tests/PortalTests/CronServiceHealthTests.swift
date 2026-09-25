import Testing
@testable import Portal

@Suite("Cron service health wire contract")
internal struct CronServiceHealthTests {
    @Test("health evidence survives cron.graph decoding for clickable service details")
    internal func decodesServiceHealthEvidence() throws {
        let value = AnyCodable.dictionary([
            "nodes": .array([
                .dictionary([
                    "id": .string("svc-meet"),
                    "kind": .string("service"),
                    "type": .string("service"),
                    "label": .string("Meet pipeline"),
                    "description": .string("Conversation service."),
                    "health": .dictionary([
                        "status": .string("unhealthy"),
                        "probe": .string("http"),
                        "target": .string("http://127.0.0.1:9120/health"),
                        "checked_at": .string("2026-08-23T22:00:00Z"),
                        "latency_ms": .double(2000),
                        "message": .string("timed out"),
                    ]),
                ]),
            ]),
            "edges": .array([]),
        ])

        let graph = try CronGraph.decodeGatewayValue(value)
        let health = try #require(graph.nodes.first?.health)

        #expect(health.status == "unhealthy")
        #expect(health.probe == "http")
        #expect(health.target == "http://127.0.0.1:9120/health")
        #expect(health.latencyMilliseconds == 2000)
        #expect(health.message == "timed out")
        #expect(!health.isHealthy)
        #expect(health.isUnhealthy)
    }

    @Test("health defaults and graph edge fallbacks remain backwards compatible")
    internal func decodesDefaultsAndSkipsMalformedItems() throws {
        let value = AnyCodable.dictionary([
            "nodes": .array([
                .dictionary([
                    "id": .string("svc-ready"),
                    "kind": .string("service"),
                    "health": .dictionary(["status": .string("healthy")]),
                ]),
                .dictionary(["kind": .string("service")]),
                .string("not-a-node"),
            ]),
            "edges": .array([
                .dictionary([
                    "source": .string("svc-ready"),
                    "target": .string("http://127.0.0.1:9120"),
                ]),
                .dictionary(["source": .string("missing-target")]),
            ]),
        ])

        let graph = try CronGraph.decodeGatewayValue(value)
        let node = try #require(graph.nodes.first)
        let health = try #require(node.health)
        let edge = try #require(graph.edges.first)

        #expect(graph.nodes.count == 1)
        #expect(node.type == "service")
        #expect(node.label == "svc-ready")
        #expect(node.description.isEmpty)
        #expect(node.enabled)
        #expect(!node.usesLLM)
        #expect(health.isHealthy)
        #expect(!health.isUnhealthy)
        #expect(health.probe == "unknown")
        #expect(health.target.isEmpty)
        #expect(health.checkedAt.isEmpty)
        #expect(health.latencyMilliseconds == 0)
        #expect(health.message.isEmpty)
        #expect(edge.type == "reads")
    }

    @Test("missing health and malformed graph envelopes are handled explicitly")
    internal func handlesMissingHealthAndInvalidEnvelope() throws {
        let value = AnyCodable.dictionary([
            "nodes": .array([
                .dictionary([
                    "id": .string("svc-live"),
                    "kind": .string("service"),
                ]),
            ]),
            "edges": .array([]),
        ])

        let graph = try CronGraph.decodeGatewayValue(value)
        #expect(graph.nodes.first?.health == nil)

        #expect(throws: GatewayError.self) {
            try CronGraph.decodeGatewayValue(.dictionary(["nodes": .array([])]))
        }
    }
}
