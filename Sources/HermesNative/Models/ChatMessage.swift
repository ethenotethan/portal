import Foundation

/// A single message in the chat conversation.
struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    var toolCalls: [ToolCallRecord]
    var reasoning: String?
    var thinkingTrace: ThinkingTrace?
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
    /// Computed eagerly on messageComplete; empty during streaming (raw content used).
    var contentWithoutAttachments: String {
        _contentWithoutAttachments ?? MediaParser.stripMediaTags(from: content)
    }

/// Cached value — set eagerly to avoid repeated regex scanning during renders.
    var _contentWithoutAttachments: String?

    enum CodingKeys: String, CodingKey {
        case id, role, content, isStreaming, toolCalls, reasoning, thinkingTrace
        case usage, status, attachments, userAttachments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        thinkingTrace = try container.decodeIfPresent(ThinkingTrace.self, forKey: .thinkingTrace)
        usage = try container.decodeIfPresent(UsageInfo.self, forKey: .usage)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        attachments = try container.decodeIfPresent([FileAttachment].self, forKey: .attachments) ?? []
        userAttachments = try container.decodeIfPresent([MediaAttachment].self, forKey: .userAttachments) ?? []
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
        thinkingTrace: ThinkingTrace? = nil,
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
        self.thinkingTrace = thinkingTrace
        self.usage = usage
        self.status = status
        self.userAttachments = userAttachments
    }
}

/// Structured model/gateway-provided thinking/reasoning trace for a single assistant turn.
/// This is shown as an expandable trace, rather than being reparsed as normal markdown
/// while the turn is streaming.
struct ThinkingTrace: Identifiable, Codable, Equatable {
    let id: UUID
    var blocks: [ThinkingBlock]
    var isStreaming: Bool
    var startedAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        blocks: [ThinkingBlock] = [],
        isStreaming: Bool = true,
        startedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.blocks = blocks
        self.isStreaming = isStreaming
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    var fullText: String {
        blocks.map(\.text).joined(separator: "\n")
    }

    var characterCount: Int {
        blocks.reduce(0) { $0 + $1.text.count }
    }

    var elapsedSeconds: Int {
        max(0, Int(updatedAt.timeIntervalSince(startedAt)))
    }

    mutating func append(_ text: String, kind: ThinkingBlock.Kind) {
        updatedAt = Date()
        if let lastIndex = blocks.indices.last, blocks[lastIndex].kind == kind, blocks[lastIndex].label == nil {
            blocks[lastIndex].text += text
            blocks[lastIndex].updatedAt = updatedAt
        } else {
            blocks.append(ThinkingBlock(kind: kind, text: text, startedAt: updatedAt, updatedAt: updatedAt))
        }
    }

    /// Append a discrete labelled block (e.g. a MoA reference answer) that
    /// lands whole — never merged with neighbouring delta blocks.
    mutating func appendDiscreteBlock(_ text: String, kind: ThinkingBlock.Kind, label: String) {
        updatedAt = Date()
        blocks.append(ThinkingBlock(kind: kind, text: text, label: label, startedAt: updatedAt, updatedAt: updatedAt))
    }

    mutating func finish() {
        isStreaming = false
        updatedAt = Date()
    }
}

struct ThinkingBlock: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, Equatable {
        case thinking
        case reasoning
        case toolStatus
        /// A Mixture-of-Agents reference answer from one slot/model.
        case moaReference
    }

    let id: UUID
    var kind: Kind
    var text: String
    /// Slot/model label for discrete blocks (MoA references). Optional so
    /// old persisted traces decode fine.
    var label: String?
    var startedAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), kind: Kind, text: String, label: String? = nil, startedAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.label = label
        self.startedAt = startedAt
        self.updatedAt = updatedAt
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
    /// Wall-clock arrival of tool.start / tool.complete. Optional so history
    /// entries (which have no timing data) and old persisted turns decode fine.
    var startedAt: Date?
    var completedAt: Date?
    /// Output-security scanner verdict (tool.output_risk). Optional so old
    /// persisted turns and unscanned tools decode fine.
    var riskLevel: ToolRiskLevel?
    var riskFindings: [String]?
    var riskRedacted: Bool?

    init(
        id: String,
        name: String,
        context: String? = nil,
        summary: String? = nil,
        durationSeconds: Double? = nil,
        inlineDiff: String? = nil,
        isComplete: Bool = false,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        riskLevel: ToolRiskLevel? = nil,
        riskFindings: [String]? = nil,
        riskRedacted: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.context = context
        self.summary = summary
        self.durationSeconds = durationSeconds
        self.inlineDiff = inlineDiff
        self.isComplete = isComplete
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.riskLevel = riskLevel
        self.riskFindings = riskFindings
        self.riskRedacted = riskRedacted
    }

    /// Apply an output-risk verdict to this record.
    mutating func applyRisk(_ payload: ToolOutputRiskPayload) {
        riskLevel = payload.risk
        riskFindings = payload.findings.isEmpty ? nil : payload.findings
        riskRedacted = payload.redacted ? true : nil
    }
}

// MARK: - File Attachment

/// A file attachment extracted from a MEDIA: tag in agent output.
struct FileAttachment: Identifiable, Codable {
    let id: UUID
    let source: Source
    var downloadState: DownloadState = .notStarted
    var mimeType: String?

    /// The source location of the attachment — local file path or remote HTTP URL.
    enum Source: Equatable, Hashable, Codable {
        case local(path: String)
        case remote(url: URL)
    }

    /// Runtime download state for remote attachments. Not persisted (excluded from Codable).
    enum DownloadState: Equatable {
        case notStarted
        case downloading(progress: Double)
        case ready(data: Data)
        case failed(error: String)
    }

    // MARK: - Computed backward-compatible properties

    /// File path. For local files, returns the absolute path.
    /// For remote files, returns the URL string (for display/logging only).
    var path: String {
        switch source {
        case .local(let p): return p
        case .remote(let url): return url.absoluteString
        }
    }

    /// Display file name extracted from the source.
    var fileName: String {
        switch source {
        case .local(let p):
            return (p as NSString).lastPathComponent
        case .remote(let url):
            return url.lastPathComponent
        }
    }

    /// File extension derived from the source.
    var fileExtension: String {
        switch source {
        case .local(let p):
            return (p as NSString).pathExtension
        case .remote(let url):
            return url.pathExtension
        }
    }

    /// Whether this attachment is a remote file that needs downloading.
    var isRemote: Bool {
        if case .remote = source { return true }
        return false
    }

    /// Whether the attachment data is ready for preview.
    var isReady: Bool {
        if case .ready = downloadState { return true }
        if case .local = source { return true }
        return false
    }

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

    /// The category derived from the source's file extension.
    var category: Category {
        Category(ext: fileExtension)
    }

    // MARK: - Initializers

    /// Local file attachment (backward-compatible with existing code).
    init(path: String) {
        self.id = UUID()
        self.source = .local(path: path)
        self.mimeType = nil
    }

    /// Remote file attachment (needs download before preview).
    init(remoteURL: URL, mimeType: String? = nil) {
        self.id = UUID()
        self.source = .remote(url: remoteURL)
        self.mimeType = mimeType
        self.downloadState = .notStarted
    }

    // MARK: - Disk Cache

    /// Base directory for persisted remote attachment downloads.
    /// Files survive app restarts so downloaded attachments stay ready.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("com.researchoors.HermesNative/attachments", isDirectory: true)
    }

    /// Deterministic cache URL for this attachment's downloaded data.
    var cacheFileURL: URL {
        let ext = fileExtension.isEmpty ? "dat" : fileExtension
        return Self.cacheDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
    }

    /// Persist downloaded data to the disk cache so it survives app restarts.
    func persistToDisk(data: Data) {
        Self.persistToCache(id: id, data: data, fileExtension: fileExtension)
    }

    /// Persist data for a specific attachment ID (static, usable before attachment is fully constructed).
    static func persistToCache(id: UUID, data: Data, fileExtension: String) {
        let fm = FileManager.default
        let ext = fileExtension.isEmpty ? "dat" : fileExtension
        let url = cacheDirectory.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[FileAttachment] Failed to persist attachment \(id) to cache: \(error)")
        }
    }

    /// Remove cached file for this attachment (cleanup after failed download, etc).
    func clearDiskCache() {
        try? FileManager.default.removeItem(at: cacheFileURL)
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id, source, mimeType
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.source = try container.decode(Source.self, forKey: .source)
        self.mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)

        // Restore from disk cache if previously downloaded
        if case .remote = source, !Self.isLocalCacheOnly {
            let cacheURL = Self.cacheDirectory.appendingPathComponent("\(id.uuidString).\(fileExtension.isEmpty ? "dat" : fileExtension)")
            if let data = try? Data(contentsOf: cacheURL) {
                self.downloadState = .ready(data: data)
            } else {
                self.downloadState = .notStarted
            }
        } else {
            self.downloadState = .notStarted
        }
    }

    /// True when running in a context where the disk cache is unavailable
    /// (unit tests, etc). Override in tests to prevent cache access.
    static var isLocalCacheOnly: Bool {
        let cached = objc_getAssociatedObject(Self.self, &cacheKey) as? Bool
        return cached ?? false
    }

    static func setLocalCacheOnly(_ value: Bool) {
        objc_setAssociatedObject(Self.self, &cacheKey, value, .OBJC_ASSOCIATION_RETAIN)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
    }
}

nonisolated(unsafe) private var cacheKey: UInt8 = 0

// MARK: - MEDIA: Parser

/// Parses MEDIA: tags from agent response text.
/// Format: `MEDIA:/absolute/path/to/file.ext` or `MEDIA:http://gateway:8642/v1/files/{session}/{file}.ext` on its own line.
struct MediaParser {
    /// Regex matching standalone MEDIA: lines (not embedded in prose).
    /// Mirrors the TUI's MEDIA_LINE_RE pattern.
    nonisolated(unsafe) private static let mediaLinePattern = /^\s*`?MEDIA:\s*(\S+?)`?\s*$/

    /// Extract all MEDIA: file paths from content.
    static func extractAttachments(from content: String) -> [FileAttachment] {
        content.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            guard let match = line.wholeMatch(of: mediaLinePattern) else { return nil }
            let captured = String(match.1)

            // Remote URL
            if captured.hasPrefix("http://") || captured.hasPrefix("https://"),
               let url = URL(string: captured) {
                return FileAttachment(remoteURL: url)
            }

            // Local file path
            let path = captured
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
