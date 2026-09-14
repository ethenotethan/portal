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
        text = replace(text, pattern: #"(?i)<br\s*/?>|</p>"#, with: "\n") // line breaks stay breaks
        text = replace(text, pattern: #"<[^>\n]+>"#, with: "") // other tags vanish, not even a pause
        text = stripTables(in: text)
        text = replace(text, pattern: #"!\[[^\]]*\]\([^)]*\)"#, with: " ") // images say nothing
        text = replace(text, pattern: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1") // [text](url) → text
        text = replace(text, pattern: #"https?://[^\s)>\]]+"#, with: options.linkPlaceholder)
        text = replace(text, pattern: #"(?m)^\s{0,3}#{1,6}\s+"#, with: "")
        text = replace(text, pattern: #"(?m)^\s{0,3}>\s?"#, with: "")
        text = replace(text, pattern: #"(?m)^\s*(?:[-*+]|\d+[.)])\s+"#, with: "")
        text = replace(text, pattern: #"(?m)^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#, with: " ")
        text = replace(text, pattern: #"`([^`\n]*)`"#, with: "$1")
        text = replace(text, pattern: #"(\*\*|__)(.+?)\1"#, with: "$2")
        text = replace(text, pattern: #"(?<![\w*])(\*|_)(?!\s)(.+?)(?<!\s)\1(?![\w*])"#, with: "$2")
        text = replace(text, pattern: #"~~(.+?)~~"#, with: "$1")
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

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
