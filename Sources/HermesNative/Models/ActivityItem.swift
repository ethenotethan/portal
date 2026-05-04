import Foundation

/// Durable notification/activity item from the Hermes gateway `activity.*` RPCs.
struct ActivityItem: Identifiable, Equatable, Hashable {
    var id: String
    var createdAt: Date
    var updatedAt: Date?
    var kind: String
    var severity: ActivitySeverity
    var source: String
    var title: String
    var summary: String
    var sessionID: String?
    var isRead: Bool
    var isDismissed: Bool
    var actions: [ActivityAction]
    var artifacts: [ActivityArtifact]
    var externalRefs: [ActivityExternalRef]

    var relativeTimestamp: String {
        createdAt.relativeString
    }

    var unreadBadgeAccessibilityLabel: String {
        isRead ? "Read" : "Unread"
    }

    static func from(_ d: [String: AnyCodable]) -> ActivityItem? {
        guard let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        let createdAt = Date(timeIntervalSince1970: d["created_at"]?.doubleValue ?? Date().timeIntervalSince1970)
        let updatedAt = d["updated_at"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
        let sessionID = d["session_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        return ActivityItem(
            id: id,
            createdAt: createdAt,
            updatedAt: updatedAt,
            kind: d["kind"]?.stringValue ?? "activity",
            severity: ActivitySeverity(rawValue: d["severity"]?.stringValue ?? "info") ?? .info,
            source: d["source"]?.stringValue ?? "gateway",
            title: d["title"]?.stringValue ?? "Activity",
            summary: d["summary"]?.stringValue ?? "",
            sessionID: sessionID,
            isRead: d["read"]?.boolValue ?? d["is_read"]?.boolValue ?? false,
            isDismissed: d["dismissed"]?.boolValue ?? d["is_dismissed"]?.boolValue ?? false,
            actions: d["actions"]?.arrayValue?.compactMap { $0.dictionaryValue.flatMap(ActivityAction.from) } ?? [],
            artifacts: d["artifacts"]?.arrayValue?.compactMap { $0.dictionaryValue.flatMap(ActivityArtifact.from) } ?? [],
            externalRefs: d["external_refs"]?.arrayValue?.compactMap { $0.dictionaryValue.flatMap(ActivityExternalRef.from) } ?? []
        )
    }
}

enum ActivitySeverity: String, Codable, Hashable {
    case info
    case warning
    case error

    var icon: String {
        switch self {
        case .info: "bell.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct ActivityAction: Identifiable, Equatable, Hashable {
    var id: String { "\(type)-\(label)-\(sessionID ?? artifactID ?? url ?? "")" }
    var type: String
    var label: String
    var sessionID: String?
    var artifactID: String?
    var url: String?

    static func from(_ d: [String: AnyCodable]) -> ActivityAction? {
        guard let type = d["type"]?.stringValue else { return nil }
        return ActivityAction(
            type: type,
            label: d["label"]?.stringValue ?? type,
            sessionID: d["session_id"]?.stringValue,
            artifactID: d["artifact_id"]?.stringValue,
            url: d["url"]?.stringValue
        )
    }
}

struct ActivityExternalRef: Identifiable, Equatable, Hashable {
    var id: String { url }
    var type: String
    var url: String
    var label: String

    static func from(_ d: [String: AnyCodable]) -> ActivityExternalRef? {
        guard let url = d["url"]?.stringValue else { return nil }
        return ActivityExternalRef(
            type: d["type"]?.stringValue ?? "link",
            url: url,
            label: d["label"]?.stringValue ?? url
        )
    }
}

struct ActivityArtifact: Identifiable, Equatable, Hashable {
    var id: String
    var name: String
    var mimeType: String
    var size: Int
    var preview: String?

    var typeLabel: String {
        if mimeType == "text/html" || name.lowercased().hasSuffix(".html") { return "HTML" }
        if mimeType == "text/markdown" || name.lowercased().hasSuffix(".md") { return "MD" }
        if mimeType == "application/pdf" || name.lowercased().hasSuffix(".pdf") { return "PDF" }
        if mimeType.hasPrefix("image/") { return "IMG" }
        if name.lowercased().hasSuffix(".log") { return "LOG" }
        if mimeType.hasPrefix("text/") { return "TXT" }
        return name.split(separator: ".").last.map { String($0).uppercased() } ?? "FILE"
    }

    static func from(_ d: [String: AnyCodable]) -> ActivityArtifact? {
        guard let id = d["id"]?.stringValue, !id.isEmpty else { return nil }
        return ActivityArtifact(
            id: id,
            name: d["name"]?.stringValue ?? "artifact",
            mimeType: d["mime_type"]?.stringValue ?? "application/octet-stream",
            size: d["size"]?.intValue ?? 0,
            preview: d["preview"]?.stringValue
        )
    }
}

struct ActivityArtifactContent: Identifiable, Equatable {
    var id: String
    var name: String
    var mimeType: String
    var encoding: String
    var content: String?
    var contentBase64: String?

    static func from(_ d: [String: AnyCodable]) -> ActivityArtifactContent? {
        guard let id = d["id"]?.stringValue else { return nil }
        return ActivityArtifactContent(
            id: id,
            name: d["name"]?.stringValue ?? "artifact",
            mimeType: d["mime_type"]?.stringValue ?? "application/octet-stream",
            encoding: d["encoding"]?.stringValue ?? "utf-8",
            content: d["content"]?.stringValue,
            contentBase64: d["content_base64"]?.stringValue
        )
    }
}
