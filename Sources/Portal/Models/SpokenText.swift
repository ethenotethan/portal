import Foundation

/// Turns an assistant message's markdown into something worth hearing.
///
/// `AVSpeechSynthesizer` reads exactly what it's given, so speaking a raw
/// response meant hearing "pound pound Summary", every asterisk, three
/// backticks followed by forty lines of Swift, and full URLs character by
/// character. This is the one place that decides what a response *sounds*
/// like, so the streaming path and the per-message path can't drift apart.
///
/// Pure and total: never throws, never returns nil; an input with nothing
/// speakable becomes the empty string, which callers treat as "skip".
internal enum SpokenText {

    /// What to say in place of a fenced code block. Empty means say nothing.
    internal struct Options: Equatable {
        internal var codeBlockPlaceholder: String = "Code block omitted."
        internal var linkPlaceholder: String = "link"

        internal init(codeBlockPlaceholder: String = "Code block omitted.", linkPlaceholder: String = "link") {
            self.codeBlockPlaceholder = codeBlockPlaceholder
            self.linkPlaceholder = linkPlaceholder
        }

        internal static let `default` = Options()
        /// Silent on code: for people who'd rather the sentence around a
        /// snippet just flow on.
        internal static let skippingCode = Options(codeBlockPlaceholder: "")
    }

    /// Prepare `markdown` for speech. Order matters: blocks first (fences,
    /// think/media tags, math), then inline syntax, then whitespace.
    internal static func prepare(_ markdown: String, options: Options = .default) -> String {
        var text = markdown
        text = MediaParser.stripMediaTags(from: text)
        text = replace(text, pattern: #"(?s)<think>.*?</think>"#, with: " ")
        text = replace(text, pattern: #"(?s)<think>.*$"#, with: " ") // unterminated, still streaming
        text = replaceCodeFences(in: text, with: options.codeBlockPlaceholder)
        text = replace(text, pattern: #"(?s)\$\$.*?\$\$"#, with: " ")
        text = replace(text, pattern: #"\$[^$\n]+\$"#, with: " ")
        text = replaceStructuredData(in: text) // bare JSON objects/arrays never reach the voice
        text = replace(text, pattern: #"(?i)<br\s*/?>|</p>"#, with: "\n") // line breaks stay breaks
        text = replace(text, pattern: #"<[^>\n]+>"#, with: "") // other tags vanish, not even a pause
        text = stripTables(in: text)
        text = replace(text, pattern: #"!\[[^\]]*\]\([^)]*\)"#, with: " ") // images say nothing
        text = replace(text, pattern: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1") // [text](url) → text
        text = replace(text, pattern: #"[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s)>\]]+"#, with: options.linkPlaceholder) // any scheme
        text = replace(text, pattern: #"(?i)\bwww\.[^\s)>\]]+"#, with: options.linkPlaceholder) // scheme-less web addresses
        text = replace(text, pattern: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "")
        text = replace(text, pattern: #"(?m)^\s{0,3}>\s?"#, with: "")
        text = replace(text, pattern: #"(?m)^\s*(?:[-*+]|\d+[.)])\s+"#, with: "")
        text = replace(text, pattern: #"(?m)^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#, with: " ")
        text = replace(text, pattern: #"`([^`\n]*)`"#, with: "$1")
        text = replace(text, pattern: #"(\*\*|__)(.+?)\1"#, with: "$2")
        text = replace(text, pattern: #"(?<![\w*])(\*|_)(?!\s)(.+?)(?<!\s)\1(?![\w*])"#, with: "$2")
        text = replace(text, pattern: #"~~(.+?)~~"#, with: "$1")
        text = stripHashes(in: text) // hex blobs, UUIDs and 0x values are noise, not words
        text = replace(text, pattern: #"[ \t]+"#, with: " ")
        text = replace(text, pattern: #"\s*\n\s*"#, with: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Blocks

    /// Replace every ``` fence (and an unterminated trailing one) with the
    /// placeholder. Fence-aware rather than regex-only so a language tag or
    /// indentation on the opening line doesn't leak into speech.
    private static func replaceCodeFences(in text: String, with placeholder: String) -> String {
        var out: [String] = []
        var inFence = false
        var pendingPlaceholder = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    inFence = false
                    if pendingPlaceholder { out.append(placeholder) }
                    pendingPlaceholder = false
                } else {
                    inFence = true
                    pendingPlaceholder = !placeholder.isEmpty
                }
                continue
            }
            if !inFence { out.append(String(line)) }
        }
        if inFence, pendingPlaceholder { out.append(placeholder) }
        return out.joined(separator: "\n")
    }

    /// A table row becomes its cells read in order, separated by commas; the
    /// `|---|---|` separator row is dropped.
    private static func stripTables(in text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { return line }
            if trimmed.range(of: #"^\|?(\s*:?-{2,}:?\s*\|)+\s*$"#, options: .regularExpression) != nil { return "" }
            return trimmed
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ") + "."
        }.joined(separator: "\n")
    }

    // MARK: - Structured data and hashes

    /// Drop bare (unfenced) JSON objects and arrays. Fenced code is already
    /// gone by the time this runs; this catches the JSON that gets emitted
    /// straight into prose, which otherwise reads as "open brace quote…".
    ///
    /// A `{`/`[` span is treated as data only when it clearly isn't a sentence:
    /// it holds a quoted key followed by a colon, or it is long and dense with
    /// structural punctuation. Short spans (`{x}`, `[1]`, `[see below]`) and
    /// ordinary bracketed asides are left to be read. Scanning is balanced and
    /// string-aware, so a nested structure collapses as one and a brace inside
    /// a string doesn't throw off the depth count.
    private static func replaceStructuredData(in text: String) -> String {
        let chars = Array(text)
        var out = ""
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" || c == "[", let end = matchedBracket(chars, from: i) {
                if looksLikeData(String(chars[i...end])) {
                    out += " "
                    i = end + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return out
    }

    /// Index of the bracket closing the one at `start`, honoring nesting and
    /// ignoring brackets inside double-quoted strings. `nil` if it never
    /// closes — e.g. a structure still being streamed — so an unbalanced run
    /// is left untouched rather than swallowing the rest of the message.
    private static func matchedBracket(_ chars: [Character], from start: Int) -> Int? {
        var depth = 0
        var inString = false
        var escaped = false
        var i = start
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                switch c {
                case "\"": inString = true
                case "{", "[": depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return i }
                default: break
                }
            }
            i += 1
        }
        return nil
    }

    private static func looksLikeData(_ span: String) -> Bool {
        // A quoted key with a colon is JSON, full stop.
        if span.range(of: #""[^"]*"\s*:"#, options: .regularExpression) != nil { return true }
        // Otherwise only a long, punctuation-dense run (a number/array dump).
        guard span.count >= 20 else { return false }
        let structural = span.reduce(into: 0) { count, ch in
            if "{}[]:,\"".contains(ch) { count += 1 }
        }
        return Double(structural) / Double(span.count) >= 0.15
    }

    /// Drop hex noise: UUIDs, `0x…` values, and long hash-like runs (commit
    /// SHAs, addresses, digests). A bare run has to be at least eight
    /// characters and carry a hex letter, so a plain decimal number (a byte
    /// count, an id) is still read and short words are untouched.
    private static func stripHashes(in text: String) -> String {
        var out = text
        out = replace(out, pattern: #"\b[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\b"#, with: " ") // UUID
        out = replace(out, pattern: #"\b0[xX][0-9a-fA-F]+\b"#, with: " ")
        out = replace(out, pattern: #"\b(?=[0-9a-fA-F]*[a-fA-F])[0-9a-fA-F]{8,}\b"#, with: " ")
        return out
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
