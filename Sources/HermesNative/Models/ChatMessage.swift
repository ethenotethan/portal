import Foundation

/// A single message in the chat conversation.
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    var toolCalls: [ToolCallRecord]
    var reasoning: String?
    var usage: UsageInfo?
    var status: String? // "complete", "interrupted", "error"
    /// Whether this message should display the avatar. Set by ChatView based on
    /// grouping logic — only the last assistant message in a turn (when not streaming)
    /// shows it, creating a "traveling avatar" that follows the latest bot activity.
    var showAvatar: Bool = false
    /// Whether this message should display its timestamp. Set by ChatView —
    /// only the last message in a consecutive same-role group shows it.
    var showTimestamp: Bool = false
    /// File attachments extracted from MEDIA: tags in the content.
    var attachments: [FileAttachment] = []

    /// Media attachments sent by the user with this message.
    var userAttachments: [MediaAttachment] = []

    /// Content with MEDIA: lines stripped (for rendering in bubbles).
    var contentWithoutAttachments: String {
        MediaParser.stripMediaTags(from: content)
    }

    enum Role: String, Equatable, Codable {
        case user
        case assistant
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        isStreaming: Bool = false,
        toolCalls: [ToolCallRecord] = [],
        reasoning: String? = nil,
        usage: UsageInfo? = nil,
        status: String? = nil,
        userAttachments: [MediaAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
        self.reasoning = reasoning
        self.usage = usage
        self.status = status
        self.userAttachments = userAttachments
    }
}

/// Record of a tool invocation within a conversation turn.
struct ToolCallRecord: Identifiable, Codable {
    let id: String         // tool_call_id from server
    var name: String
    var context: String?   // Preview text from tool.start
    var summary: String?   // Summary from tool.complete
    var durationSeconds: Double?
    var inlineDiff: String?
    var isComplete: Bool

    init(
        id: String,
        name: String,
        context: String? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil,
        inlineDiff: String? = nil,
        isComplete: Bool = false
    ) {
        self.id = id
        self.name = name
        self.context = context
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.inlineDiff = inlineDiff
        self.isComplete = isComplete
    }
}

// MARK: - File Attachment

/// A file attachment extracted from a MEDIA: tag in agent output.
struct FileAttachment: Identifiable, Codable {
    let id = UUID()
    let path: String
    let fileName: String
    let fileExtension: String
    let category: Category

    enum Category: String, Codable {
        case html
        case pdf
        case image
        case audio
        case video
        case other

        init(ext: String) {
            switch ext.lowercased() {
            case "html", "htm":       self = .html
            case "pdf":               self = .pdf
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "tiff":
                self = .image
            case "mp3", "wav", "ogg", "m4a", "flac", "aac":
                self = .audio
            case "mp4", "mov", "avi", "mkv", "webm":
                self = .video
            default:                  self = .other
            }
        }

        /// SF Symbol icon for this category.
        var icon: String {
            switch self {
            case .html:  "safari"
            case .pdf:   "doc.richtext"
            case .image: "photo"
            case .audio: "waveform"
            case .video: "film"
            case .other: "doc"
            }
        }
    }

    init(path: String) {
        self.path = path
        self.fileName = (path as NSString).lastPathComponent
        self.fileExtension = (path as NSString).pathExtension
        self.category = Category(ext: self.fileExtension)
    }
}

// MARK: - MEDIA: Parser

/// Parses MEDIA: tags from agent response text.
/// Format: `MEDIA:/absolute/path/to/file.ext` on its own line.
struct MediaParser {
    /// Regex matching standalone MEDIA: lines (not embedded in prose).
    /// Mirrors the TUI's MEDIA_LINE_RE pattern.
    private static nonisolated(unsafe) let mediaLinePattern = /^\s*`?MEDIA:\s*(\S+?)`?\s*$/

    /// Extract all MEDIA: file paths from content.
    static func extractAttachments(from content: String) -> [FileAttachment] {
        content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard let match = line.wholeMatch(of: mediaLinePattern) else { return nil }
            let path = String(match.1)
            // Verify file exists
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return FileAttachment(path: path)
        }
    }

    /// Return content with MEDIA: lines stripped.
    static func stripMediaTags(from content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                line.wholeMatch(of: mediaLinePattern) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
