import Testing
import Foundation
@testable import Portal

@Suite("Activity Item")
struct ActivityItemTests {
    @Test("parses gateway activity item with artifact and action")
    func parseActivityItem() {
        let payload: [String: AnyCodable] = [
            "id": AnyCodable("act_123"),
            "created_at": AnyCodable(1_700_000_000.0),
            "updated_at": AnyCodable(1_700_000_010.0),
            "kind": AnyCodable("report.generated"),
            "severity": AnyCodable("warning"),
            "source": AnyCodable("cron"),
            "title": AnyCodable("Report ready"),
            "summary": AnyCodable("Open the HTML report"),
            "session_id": AnyCodable("sid123"),
            "read": AnyCodable(false),
            "dismissed": AnyCodable(false),
            "actions": .array([
                .dictionary([
                    "type": AnyCodable("open_session"),
                    "label": AnyCodable("Open session"),
                    "session_id": AnyCodable("sid123"),
                ])
            ]),
            "artifacts": .array([
                .dictionary([
                    "id": AnyCodable("art_123"),
                    "name": AnyCodable("report.html"),
                    "mime_type": AnyCodable("text/html"),
                    "size": AnyCodable(42),
                    "preview": AnyCodable("HTML report"),
                ])
            ]),
            "external_refs": .array([
                .dictionary([
                    "type": AnyCodable("telegram_message"),
                    "url": AnyCodable("https://t.me/c/example"),
                    "label": AnyCodable("Open Telegram"),
                ])
            ]),
        ]

        let item = ActivityItem.from(payload)
        #expect(item?.id == "act_123")
        #expect(item?.severity == .warning)
        #expect(item?.artifacts.first?.typeLabel == "HTML")
        #expect(item?.actions.first?.type == "open_session")
        #expect(item?.externalRefs.first?.label == "Open Telegram")
    }

    @Test("parses activity.created gateway event")
    func parseActivityCreatedGatewayEvent() {
        let activity: [String: AnyCodable] = [
            "id": AnyCodable("act_evt"),
            "created_at": AnyCodable(1_700_000_000.0),
            "kind": AnyCodable("approval.request"),
            "severity": AnyCodable("warning"),
            "source": AnyCodable("approval"),
            "title": AnyCodable("Approval required"),
            "summary": AnyCodable("Run command"),
            "read": AnyCodable(false),
            "dismissed": AnyCodable(false),
        ]

        let event = GatewayEvent.from(type: "activity.created", payload: .dictionary(["activity": .dictionary(activity)]))
        if case .activityCreated(let item) = event {
            #expect(item.id == "act_evt")
            #expect(item.title == "Approval required")
        } else {
            Issue.record("Expected activityCreated event")
        }
    }

    @Test("parses dismissed and read flag aliases from gateway payloads")
    func parsesReadDismissedAliases() {
        let payload: [String: AnyCodable] = [
            "id": AnyCodable("act_aliases"),
            "is_read": AnyCodable(true),
            "is_dismissed": AnyCodable(true),
        ]

        let item = ActivityItem.from(payload)
        #expect(item?.isRead == true)
        #expect(item?.isDismissed == true)
    }

    @Test("artifact type labels recognize MIME types and filename fallbacks")
    internal func artifactTypeLabels() {
        let cases: [(name: String, mimeType: String, expected: String)] = [
            ("notes", "text/markdown", "MD"),
            ("report.PDF", "application/octet-stream", "PDF"),
            ("photo", "image/png", "IMG"),
            ("server.LOG", "application/octet-stream", "LOG"),
            ("readme", "text/plain", "TXT"),
            ("archive.zip", "application/octet-stream", "ZIP"),
            ("README", "application/octet-stream", "README"),
        ]

        for testCase in cases {
            let artifact = ActivityArtifact(
                id: testCase.name,
                name: testCase.name,
                mimeType: testCase.mimeType,
                size: 0,
                preview: nil
            )
            #expect(artifact.typeLabel == testCase.expected)
        }
    }

    @Test("activity events parse direct payloads as well as nested activity payloads")
    func parseDirectActivityPayloadGatewayEvent() {
        let direct = GatewayEvent.from(type: "activity.created", payload: .dictionary([
            "id": AnyCodable("act_direct"),
            "title": AnyCodable("Direct activity"),
        ]))
        let nested = GatewayEvent.from(type: "activity.updated", payload: .dictionary([
            "activity": .dictionary([
                "id": AnyCodable("act_nested"),
                "title": AnyCodable("Nested activity"),
            ])
        ]))

        if case .activityCreated(let directItem) = direct {
            #expect(directItem.id == "act_direct")
        } else {
            Issue.record("Expected direct activity.created event")
        }

        if case .activityUpdated(let nestedItem) = nested {
            #expect(nestedItem.id == "act_nested")
        } else {
            Issue.record("Expected nested activity.updated event")
        }
    }
}
