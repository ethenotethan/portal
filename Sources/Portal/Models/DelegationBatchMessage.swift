import Foundation

/// A parsed async-delegation *batch* completion report — the multi-task block
/// the gateway re-injects as an assistant message when a fan-out of subagents
/// finishes. The raw text is a header line, a preamble, and one
/// `--- ✓ TASK n/m … ---` section per subagent (see `process_registry.py`'s
/// `_format_async_delegation`), which reads as an unformatted wall through the
/// plain markdown bubble. Parsing it into cards is what makes it legible.
///
/// This is deliberately the *rich* sibling of `ChatMessage.delegationBatchNoticeLabel`
/// (which handles only the bare `[…]` marker with no body). Parsing is pure and
/// resilient: an unrecognized shape yields `nil` and the message renders as
/// ordinary markdown, never worse than today.
internal struct DelegationBatchMessage: Equatable {
    /// The batch id from the header (e.g. `deleg_72e3ab62`), or `nil` when the
    /// gateway emitted the header without one.
    internal let delegationID: String?
    /// Total wall-clock for the batch, pulled from the preamble's `Total
    /// duration:` field when present.
    internal let totalDurationSeconds: Double?
    /// Compact preamble captions worth keeping (Dispatched / Context / Toolsets
    /// / Role+Model). The boilerplate intro sentence is dropped — the header
    /// card already says "delegation batch complete".
    internal let metaLines: [String]
    /// One card per subagent, in task order.
    internal let tasks: [Task]
    /// Set when the batch failed wholesale (`--- ERROR ---`) with no per-task
    /// results.
    internal let batchError: String?

    /// One subagent's result within the batch.
    internal struct Task: Equatable, Identifiable {
        /// Stable identity for `ForEach` — the 1-based display index.
        internal var id: Int { index }
        /// 1-based position shown to the reader.
        internal let index: Int
        /// Batch size (the `n` in `n/m`).
        internal let total: Int
        /// `true` for the ✓ glyph (status `completed`/`success`), `false` for ✗.
        internal let succeeded: Bool
        /// Raw status token (`completed`, `failed`, `timeout`, …).
        internal let status: String
        /// API-call count when the gateway recorded a non-zero one.
        internal let apiCalls: Int?
        /// Subagent wall-clock in seconds when recorded.
        internal let durationSeconds: Double?
        /// The task goal / description, when the header carried one.
        internal let goal: String?
        /// The subagent's summary body, as markdown, with the truncation footer
        /// and live-transcript line lifted out into their own fields.
        internal let body: String
        /// Present when the summary was head/tail trimmed to protect the
        /// parent's context window.
        internal let truncation: Truncation?
        /// Path to the full tool/assistant trace, when the gateway saved one.
        internal let liveTranscript: String?
    }

    /// The `[SUMMARY TRUNCATED]` footer, reduced to the facts worth surfacing.
    internal struct Truncation: Equatable {
        internal let headChars: Int?
        internal let tailChars: Int?
        internal let totalChars: Int?
        /// Where the full untrimmed summary was spilled to disk.
        internal let spillPath: String?
    }

    /// The header prefix that gates the whole parse. The gateway always emits
    /// this as the literal first line, so a cheap prefix check keeps the parser
    /// off the hot path for ordinary messages.
    private static let headerPrefix = "[ASYNC DELEGATION BATCH COMPLETE"

    // MARK: - Parse

    /// Parse `content` into a batch report, or `nil` if it isn't one.
    internal static func parse(_ content: String) -> DelegationBatchMessage? {
        // Cheap guard: only pay for the full line split on the rare message that
        // opens with the batch header (tolerating a little leading whitespace).
        guard content.drop(while: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .hasPrefix(headerPrefix) else { return nil }

        let lines = content.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return nil }

        let header = lines[headerIdx].trimmingCharacters(in: .whitespaces)
        guard header.hasPrefix(headerPrefix), header.hasSuffix("]") else { return nil }
        let delegationID = Self.delegationID(fromHeader: header)

        let rest = Array(lines[(headerIdx + 1)...])
        let segments = Self.segment(rest)

        let batchError = Self.batchError(from: segments)
        let tasks = segments.taskBlocks.compactMap(Self.parseTask)

        // A header we can't turn into at least one task or an error isn't worth
        // hijacking the markdown path for — fall back rather than show an empty card.
        guard !tasks.isEmpty || batchError != nil else { return nil }

        let (meta, totalDur) = Self.parsePreamble(segments.preamble)
        return DelegationBatchMessage(
            delegationID: delegationID,
            totalDurationSeconds: totalDur,
            metaLines: meta,
            tasks: tasks,
            batchError: batchError
        )
    }

    /// Pull the id that follows the em-dash in `[… COMPLETE — <id>]`.
    private static func delegationID(fromHeader header: String) -> String? {
        let inner = header.dropFirst().dropLast() // strip [ ]
        guard let range = inner.range(of: " — ") else { return nil }
        let id = inner[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : id
    }

    // MARK: - Segmentation

    private struct Segments {
        var preamble: [String]
        var taskBlocks: [[String]] // each includes its `--- … ---` delimiter as line 0
        var errorLines: [String]?
    }

    /// A `--- … ---` rule that opens a task section.
    private static func isTaskDelimiter(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("--- ") && t.hasSuffix(" ---") && t.contains(" TASK ")
    }

    private static func isErrorDelimiter(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "--- ERROR ---"
    }

    /// Split the post-header lines into the preamble, one block per task, and
    /// any trailing `--- ERROR ---` block.
    private static func segment(_ lines: [String]) -> Segments {
        var preamble: [String] = []
        var blocks: [[String]] = []
        var errorLines: [String]?
        var current: [String]?
        var inError = false

        for line in lines {
            if isTaskDelimiter(line) {
                if let block = current, !inError { blocks.append(block) }
                current = [line]
                inError = false
            } else if isErrorDelimiter(line) {
                if let block = current, !inError { blocks.append(block) }
                current = []
                inError = true
            } else if current != nil {
                current?.append(line)
            } else {
                preamble.append(line)
            }
        }
        if let block = current {
            if inError { errorLines = block } else { blocks.append(block) }
        }
        return Segments(preamble: preamble, taskBlocks: blocks, errorLines: errorLines)
    }

    private static func batchError(from segments: Segments) -> String? {
        guard let errorLines = segments.errorLines else { return nil }
        let text = errorLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Preamble

    /// Keep the short informative captions; drop the boilerplate intro sentence
    /// (everything up to the first blank line) and pull out the total duration.
    private static func parsePreamble(_ lines: [String]) -> (meta: [String], totalDuration: Double?) {
        // Skip leading blanks, then the intro paragraph, then a blank.
        var idx = 0
        while idx < lines.count, lines[idx].trimmingCharacters(in: .whitespaces).isEmpty { idx += 1 }
        while idx < lines.count, !lines[idx].trimmingCharacters(in: .whitespaces).isEmpty { idx += 1 }

        var meta: [String] = []
        var totalDuration: Double?
        for line in lines[idx...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            meta.append(trimmed)
            if let range = trimmed.range(of: "Total duration:") {
                totalDuration = seconds(inTrailing: String(trimmed[range.upperBound...]))
            }
        }
        return (meta, totalDuration)
    }

    // MARK: - Task block

    /// Parse one `--- … ---`-led block into a `Task`. Returns `nil` if the
    /// delimiter can't be read as a task header.
    private static func parseTask(_ block: [String]) -> Task? {
        guard let delimiter = block.first else { return nil }
        guard let head = parseTaskHeader(delimiter) else { return nil }

        let bodyLines = Array(block.dropFirst())
        let extracted = extractFooters(bodyLines)
        return Task(
            index: head.index,
            total: head.total,
            succeeded: head.succeeded,
            status: head.status,
            apiCalls: head.apiCalls,
            durationSeconds: head.duration,
            goal: head.goal,
            body: extracted.body,
            truncation: extracted.truncation,
            liveTranscript: extracted.liveTranscript
        )
    }

    private struct TaskHeader {
        let index: Int
        let total: Int
        let succeeded: Bool
        let status: String
        let apiCalls: Int?
        let duration: Double?
        let goal: String?
    }

    /// Read `--- ✓ TASK 1/3: goal  (status=completed, api_calls=8, 184.6s) ---`.
    private static func parseTaskHeader(_ line: String) -> TaskHeader? {
        var inner = line.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("--- "), inner.hasSuffix(" ---") else { return nil }
        inner = String(inner.dropFirst(4).dropLast(4)) // strip the rule fences

        // Glyph is a single leading grapheme; ✓ = success, anything else = failure.
        guard let glyph = inner.first else { return nil }
        let succeeded = (glyph == "✓")
        inner = inner.dropFirst().trimmingCharacters(in: .whitespaces) // now "TASK 1/3: goal  (status=…)"

        guard inner.hasPrefix("TASK ") else { return nil }
        inner = String(inner.dropFirst("TASK ".count))

        // Split off the trailing `(status=…)` — anchor on the literal so a goal
        // containing parentheses (e.g. "Audit API (v2)") can't be mistaken for it.
        guard let statusRange = inner.range(of: "(status=", options: .backwards) else { return nil }
        let prefix = String(inner[..<statusRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        var fields = String(inner[statusRange.lowerBound...])
        guard fields.hasPrefix("("), fields.hasSuffix(")") else { return nil }
        fields = String(fields.dropFirst().dropLast()) // "status=completed, api_calls=8, 184.6s"

        // prefix = "1/3: goal" or "1/3"
        let indexPart: String
        let goal: String?
        if let colon = prefix.range(of: ": ") {
            indexPart = String(prefix[..<colon.lowerBound])
            let g = String(prefix[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            goal = g.isEmpty ? nil : g
        } else {
            indexPart = prefix
            goal = nil
        }
        let counts = indexPart.split(separator: "/")
        guard counts.count == 2,
              let index = Int(counts[0].trimmingCharacters(in: .whitespaces)),
              let total = Int(counts[1].trimmingCharacters(in: .whitespaces)) else { return nil }

        let parsed = parseStatusFields(fields)
        return TaskHeader(
            index: index, total: total, succeeded: succeeded,
            status: parsed.status, apiCalls: parsed.apiCalls,
            duration: parsed.duration, goal: goal
        )
    }

    /// Parse `status=completed, api_calls=8, 184.6s` into typed fields.
    private static func parseStatusFields(
        _ fields: String
    ) -> (status: String, apiCalls: Int?, duration: Double?) {
        var status = "?"
        var apiCalls: Int?
        var duration: Double?
        for raw in fields.components(separatedBy: ", ") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if let range = token.range(of: "status=") {
                status = String(token[range.upperBound...])
            } else if let range = token.range(of: "api_calls=") {
                apiCalls = Int(token[range.upperBound...])
            } else if token.hasSuffix("s"), let value = Double(token.dropLast()) {
                duration = value
            }
        }
        return (status, apiCalls, duration)
    }

    // MARK: - Footers (truncation + live transcript)

    private static func extractFooters(
        _ bodyLines: [String]
    ) -> (body: String, truncation: Truncation?, liveTranscript: String?) {
        var lines = bodyLines
        let liveTranscript = takeLiveTranscript(&lines)
        let truncation = takeTruncation(&lines)
        // The head/tail split marker is redundant once the footer is a chip.
        lines.removeAll { $0.contains("middle omitted") && $0.contains("[") }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (body, truncation, liveTranscript)
    }

    private static func takeLiveTranscript(_ lines: inout [String]) -> String? {
        guard let idx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Full live transcript")
        }) else { return nil }
        let line = lines[idx]
        lines.remove(at: idx)
        guard let range = line.range(of: ": ") else { return nil }
        let path = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : path
    }

    private static func takeTruncation(_ lines: inout [String]) -> Truncation? {
        guard let start = lines.firstIndex(where: { $0.contains("[SUMMARY TRUNCATED]") }) else {
            return nil
        }
        // The footer runs to the next all-box-drawing rule (the closing "─" * 37).
        var end = start
        var probe = start + 1
        while probe < lines.count {
            let t = lines[probe].trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.allSatisfy({ $0 == "\u{2500}" }) { end = probe; break }
            probe += 1
        }
        if end == start { end = min(lines.count - 1, start + 3) } // resilient fallback

        var truncation = Truncation(headChars: nil, tailChars: nil, totalChars: nil, spillPath: nil)
        for line in lines[start...end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Showing"), trimmed.contains("chars") {
                let nums = integers(in: trimmed)
                truncation = Truncation(
                    headChars: nums.first,
                    tailChars: nums.count > 1 ? nums[1] : nil,
                    totalChars: nums.count > 2 ? nums[2] : nil,
                    spillPath: truncation.spillPath
                )
            } else if let range = trimmed.range(of: "Full subagent output saved to: ") {
                let path = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                truncation = Truncation(
                    headChars: truncation.headChars, tailChars: truncation.tailChars,
                    totalChars: truncation.totalChars, spillPath: path.isEmpty ? nil : path
                )
            }
        }

        // Drop the footer block, plus a single blank line that preceded it.
        lines.removeSubrange(start...end)
        if start > 0, start - 1 < lines.count,
           lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            lines.remove(at: start - 1)
        }
        return truncation
    }

    // MARK: - Number helpers

    /// Every integer embedded in `text`, tolerating `,` thousands separators.
    private static func integers(in text: String) -> [Int] {
        var result: [Int] = []
        var current = ""
        for ch in text {
            if ch.isNumber {
                current.append(ch)
            } else if ch == "," {
                continue
            } else {
                if let value = Int(current) { result.append(value) }
                current = ""
            }
        }
        if let value = Int(current) { result.append(value) }
        return result
    }

    /// Read the first `<number>s` token in `text` (e.g. " 372.4s" → 372.4).
    private static func seconds(inTrailing text: String) -> Double? {
        for raw in text.components(separatedBy: .whitespaces) {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if token.hasSuffix("s"), let value = Double(token.dropLast()) { return value }
        }
        return nil
    }
}
