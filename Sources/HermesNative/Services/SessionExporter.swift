import Foundation

/// Exports a chat session's full context as a self-contained Markdown document
/// (the primary deliverable — paste-able into another agent as context) and as
/// a rendered PDF for human sharing.
///
/// The markdown core is a pure function over the session's messages so it is
/// deterministic and unit-testable: same input, same output. Attachments are
/// referenced by filename/path — binaries are never embedded.
enum SessionExporter {

    /// Optional metadata rendered into the document header. Everything is
    /// best-effort: pass nil for anything unknown and the line is omitted.
    struct Metadata {
        var title: String
        var sessionID: String?
        var gatewayName: String?
        var model: String?
        var source: String?
        var startedAt: Date?
        var lastActive: Date?
        var usage: SessionUsage?
        var assistantName: String

        init(
            title: String,
            sessionID: String? = nil,
            gatewayName: String? = nil,
            model: String? = nil,
            source: String? = nil,
            startedAt: Date? = nil,
            lastActive: Date? = nil,
            usage: SessionUsage? = nil,
            assistantName: String = "Assistant"
        ) {
            self.title = title
            self.sessionID = sessionID
            self.gatewayName = gatewayName
            self.model = model
            self.source = source
            self.startedAt = startedAt
            self.lastActive = lastActive
            self.usage = usage
            self.assistantName = assistantName
        }
    }

    // MARK: - Markdown

    /// Render the full session transcript to a single markdown document.
    ///
    /// - Parameters:
    ///   - messages: transcript in display order (preserved verbatim).
    ///   - metadata: session header fields; missing values are omitted.
    ///   - exportDate: injectable for deterministic tests.
    ///   - timeZone: injectable for deterministic tests.
    static func markdown(
        messages: [ChatMessage],
        metadata: Metadata,
        exportDate: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        var lines: [String] = []
        lines.append("# \(metadata.title)")
        lines.append("")
        lines.append(contentsOf: headerLines(metadata: metadata, messageCount: messages.count,
                                             exportDate: exportDate, timeZone: timeZone))
        lines.append("")
        lines.append("> Note: images and file attachments are referenced by filename, not embedded.")
        lines.append("")

        if messages.isEmpty {
            lines.append("_This session has no messages._")
            return lines.joined(separator: "\n") + "\n"
        }

        for message in messages {
            lines.append("---")
            lines.append("")
            switch message.role {
            case .user:
                lines.append(contentsOf: userSection(message))
            case .assistant:
                lines.append(contentsOf: assistantSection(message, assistantName: metadata.assistantName,
                                                          timeZone: timeZone))
            }
            lines.append("")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func headerLines(
        metadata: Metadata,
        messageCount: Int,
        exportDate: Date,
        timeZone: TimeZone
    ) -> [String] {
        var lines: [String] = []
        if let id = metadata.sessionID, !id.isEmpty {
            lines.append("- **Session:** `\(id)`")
        }
        if let gateway = metadata.gatewayName, !gateway.isEmpty {
            lines.append("- **Gateway:** \(gateway)")
        }
        if let model = metadata.model, !model.isEmpty {
            lines.append("- **Model:** `\(model)`")
        }
        if let source = metadata.source, !source.isEmpty {
            lines.append("- **Source:** \(source)")
        }
        if let start = metadata.startedAt {
            let end = metadata.lastActive.map { " – \(format($0, timeZone: timeZone))" } ?? ""
            lines.append("- **Date range:** \(format(start, timeZone: timeZone))\(end)")
        }
        lines.append("- **Messages:** \(messageCount)")
        if let usage = metadata.usage {
            var parts = ["\(usage.inputTokens) in / \(usage.outputTokens) out / \(usage.totalTokens) total tokens"]
            if usage.apiCalls > 0 { parts.append("\(usage.apiCalls) API calls") }
            if let cost = usage.costUSD { parts.append(String(format: "$%.4f", cost)) }
            lines.append("- **Usage:** \(parts.joined(separator: ", "))")
        }
        lines.append("- **Exported:** \(format(exportDate, timeZone: timeZone)) by Hermes Native")
        return lines
    }

    private static func userSection(_ message: ChatMessage) -> [String] {
        var lines = ["## 👤 User", ""]
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(content.isEmpty ? "_(empty message)_" : content)
        if !message.userAttachments.isEmpty {
            lines.append("")
            let names = message.userAttachments.map { "`\($0.fileName)`" }.joined(separator: ", ")
            lines.append("**Attachments (referenced, not embedded):** \(names)")
        }
        return lines
    }

    private static func assistantSection(
        _ message: ChatMessage,
        assistantName: String,
        timeZone: TimeZone
    ) -> [String] {
        var lines = ["## 🤖 \(assistantName)", ""]

        // Reasoning / thinking first — chronologically it precedes the answer.
        let reasoningText = message.thinkingTrace?.fullText ?? message.reasoning
        if let reasoning = reasoningText?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoning.isEmpty {
            lines.append("<details>")
            lines.append("<summary>💭 Reasoning</summary>")
            lines.append("")
            lines.append(contentsOf: fenced(reasoning, language: "text"))
            lines.append("")
            lines.append("</details>")
            lines.append("")
        }

        for tool in message.toolCalls {
            lines.append(contentsOf: toolSection(tool, timeZone: timeZone))
            lines.append("")
        }

        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            lines.append(content)
        } else if message.toolCalls.isEmpty && (reasoningText ?? "").isEmpty {
            lines.append("_(empty message)_")
        }

        if let status = message.status, status != "complete" {
            lines.append("")
            lines.append("_Turn status: \(status)_")
        }

        if !message.attachments.isEmpty {
            lines.append("")
            let names = message.attachments.map { "`\($0.fileName)`" }.joined(separator: ", ")
            lines.append("**Attachments (referenced, not embedded):** \(names)")
        }
        return lines
    }

    private static func toolSection(_ tool: ToolCallRecord, timeZone: TimeZone) -> [String] {
        var heading = "### 🔧 tool: \(tool.name)"
        var annotations: [String] = []
        if let started = tool.startedAt {
            annotations.append(timeOnly(started, timeZone: timeZone))
        }
        if let duration = tool.durationSeconds {
            annotations.append(String(format: "%.1fs", duration))
        }
        if !tool.isComplete {
            annotations.append("incomplete")
        }
        if !annotations.isEmpty {
            heading += " (\(annotations.joined(separator: ", ")))"
        }
        var lines = [heading, ""]
        if let context = tool.context?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty {
            lines.append("**Input:**")
            lines.append("")
            lines.append(contentsOf: fenced(context, language: "text"))
            lines.append("")
        }
        if let summary = tool.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            lines.append("**Result:**")
            lines.append("")
            lines.append(contentsOf: fenced(summary, language: "text"))
            lines.append("")
        }
        if let diff = tool.inlineDiff?.trimmingCharacters(in: .whitespacesAndNewlines), !diff.isEmpty {
            lines.append("**Diff:**")
            lines.append("")
            lines.append(contentsOf: fenced(diff, language: "diff"))
            lines.append("")
        }
        if lines.count > 2 { lines.removeLast() } // drop trailing blank inside the section
        return lines
    }

    /// Wrap `text` in a code fence guaranteed longer than any backtick run
    /// inside it, so embedded ``` blocks survive round-tripping.
    static func fenced(_ text: String, language: String = "") -> [String] {
        var longestRun = 0
        var current = 0
        for char in text {
            if char == "`" {
                current += 1
                longestRun = max(longestRun, current)
            } else {
                current = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return ["\(fence)\(language)"] + text.components(separatedBy: "\n") + [fence]
    }

    // MARK: - Filenames

    /// `<session-title-slug>-<yyyyMMdd-HHmm>.<ext>` — filesystem-safe.
    static func filename(title: String, fileExtension: String, date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let slug = slugify(title)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "\(slug)-\(formatter.string(from: date)).\(fileExtension)"
    }

    static func slugify(_ title: String) -> String {
        let lowered = title.lowercased()
        var slug = ""
        var lastWasDash = true // suppress leading dash
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 60 { slug = String(slug.prefix(60)) }
        return slug.isEmpty ? "hermes-session" : slug
    }

    // MARK: - Date formatting

    private static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func timeOnly(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
