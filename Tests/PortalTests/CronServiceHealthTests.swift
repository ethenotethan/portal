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
    }
}
