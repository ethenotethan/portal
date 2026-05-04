import Testing
import Foundation
@testable import HermesNative

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
}
