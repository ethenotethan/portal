import Foundation

/// One turn in a local side-discussion.
///
/// Deliberately its own type rather than `ChatMessage`: these turns never enter
/// the session transcript, carry no tool calls / usage / graph snapshot, and are
/// discarded when the discussion ends. Keeping them separate is what makes the
/// feature safe — nothing here can be mistaken for something the agent said.
internal struct LocalDiscussionTurn: Identifiable, Equatable, Sendable {
    internal enum Role: Sendable {
        case user
        case assistant
    }

    internal let id: UUID
    internal let role: Role
    internal var text: String
    /// True while a reply is still arriving token by token.
    internal var isStreaming: Bool

    internal init(id: UUID = UUID(), role: Role, text: String, isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.isStreaming = isStreaming
    }
}

/// A spoken side-conversation with the on-device model, anchored to one
/// assistant message.
///
/// The anchor is what the user wants to talk *about*: its text — plus the
/// options it offered, when the reasoning summarizer found any — becomes the
/// model's grounding, so "why B?" resolves against the actual reply instead of
/// thin air. The discussion is scratch space: it costs no gateway tokens, never
/// appears in `ChatViewModel.messages`, and is thrown away on end unless the
/// user explicitly hands its conclusion to the agent.
internal struct LocalDiscussion: Identifiable, Equatable, Sendable {
    /// The anchor message's id, so a second "discuss" tap on the same message
    /// resumes rather than duplicates.
    internal let id: UUID
    /// The anchor reply, already trimmed to a context budget the small local
    /// models can actually attend to (see `Self.anchorBudget`).
    internal let anchorText: String
    /// Options the anchor offered ("Reply A, B, or C"), when a reasoning
    /// summary made them explicit. Empty is normal and fine.
    internal let options: [String]
    internal var turns: [LocalDiscussionTurn]

    /// How much of the anchor reply is handed to the model. A 1-4B model given
    /// 8k characters of context answers about the middle of it; the head is
    /// where the claim being discussed almost always is.
    internal static let anchorBudget = 1_600

    internal init(anchorID: UUID, anchorText: String, options: [String] = [], turns: [LocalDiscussionTurn] = []) {
        self.id = anchorID
        self.anchorText = Self.trimAnchor(anchorText)
        self.options = options
        self.turns = turns
    }

    /// Whether there's anything worth handing back to the agent.
    internal var hasExchange: Bool {
        turns.contains { $0.role == .assistant && !$0.text.isEmpty }
    }

    /// Head of the anchor, cut on a paragraph boundary when one is close to the
    /// budget so the model isn't handed a sentence that stops mid-clause.
    internal static func trimAnchor(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > anchorBudget else { return trimmed }
        let head = String(trimmed.prefix(anchorBudget))
        if let lastBreak = head.range(of: "\n\n", options: .backwards),
           head.distance(from: head.startIndex, to: lastBreak.lowerBound) > anchorBudget / 2 {
            return String(head[head.startIndex..<lastBreak.lowerBound])
        }
        return head
    }

    // MARK: - Options

    /// Pull the choices a reply offered out of its text — the "Reply A, B, or C"
    /// case that started this whole feature.
    ///
    /// Deliberately not `HeuristicReasoningSummarizer.extractDecisions`: that
    /// reads *reasoning traces* and falls back to "first meaningful line" when
    /// nothing matches, which here would hand the model a confident list of one
    /// fake option. This only recognizes an actual enumerated list, and returning
    /// nothing is a perfectly good answer.
    ///
    /// Two markers of the same kind are the minimum, because a lone "1." is a
    /// step in a procedure, not a choice.
    internal static func detectOptions(in text: String) -> [String] {
        var lettered: [String] = []
        var numbered: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count))
            }
            line = line.replacingOccurrences(of: "**", with: "")
            if line.lowercased().hasPrefix("option ") { line = String(line.dropFirst("option ".count)) }
            guard let marker = line.first, let body = optionBody(of: line) else { continue }
            if marker.isLetter, marker.isUppercase {
                lettered.append(body)
            } else if marker.isNumber, marker != "0" {
                numbered.append(body)
            }
        }

        let options = lettered.count >= 2 ? lettered : (numbered.count >= 2 ? numbered : [])
        return Array(options.prefix(6))
    }

    /// The text after a `A.` / `2)` / `C:` marker, or nil when the line isn't one.
    private static func optionBody(of line: String) -> String? {
        var characters = Array(line)
        guard characters.count > 3 else { return nil }
        guard characters[0].isLetter || characters[0].isNumber else { return nil }
        guard [".", ")", ":"].contains(String(characters[1])) else { return nil }
        guard characters[2] == " " else { return nil }
        characters.removeFirst(3)
        let body = String(characters).trimmingCharacters(in: .whitespaces)
        // A whole paragraph under a numbered heading isn't a spoken option; the
        // model gets the full reply anyway, so a long line adds only noise.
        guard body.count >= 2, body.count <= 200 else { return nil }
        return body
    }

    // MARK: - Prompting

    /// System instructions for the discussion. Held constant for the whole
    /// exchange so the engine can keep one chat session (and its KV cache)
    /// alive across turns — see `LocalChatService.respond`.
    ///
    /// Three things this has to get right, all of them learned from what small
    /// models do wrong when spoken aloud: length (a paragraph read by a
    /// synthesizer is interminable), formatting (markdown read aloud is
    /// gibberish — "asterisk asterisk"), and honesty (the model can see the
    /// quoted reply and nothing else, so it must decline rather than invent
    /// repo details).
    internal func instructions() -> String {
        var prompt = """
        You are a thinking partner in a SPOKEN conversation. The user is an experienced \
        engineer talking out loud with you about a reply they just received from a coding \
        agent. The reply is quoted below.

        How to answer:
        - You are being read aloud by a speech synthesizer. Answer in one to three short \
        sentences. No markdown, no bullet lists, no code blocks, no headings.
        - Discuss what is actually in the reply. Quote its own words when it helps.
        - You can see ONLY the quoted reply — not their repository, files, or history. If \
        a question needs something you cannot see, say what you'd need to know instead of \
        guessing at specifics.
        - Skip preamble, apologies, and flattery. Answer the question, then stop.
        - Take a position when asked for one. "Both are reasonable" is not an answer.
        """

        if !options.isEmpty {
            let list = options.enumerated()
                .map { index, option in "  \(index + 1). \(option)" }
                .joined(separator: "\n")
            prompt += """


            The reply offered these options:
            \(list)
            """
        }

        prompt += """


        The reply under discussion:
        \"\"\"
        \(anchorText)
        \"\"\"
        """
        return prompt
    }

    /// The prompt that hands the discussion's conclusion back to the real agent.
    ///
    /// The point of the feature: talk it out locally for free, then spend one
    /// gateway turn on the decision you actually reached. The local model's side
    /// is included but labelled as a local model's, so the agent weighs it as
    /// scratch thinking rather than as prior instruction from the user.
    internal func handoffPrompt() -> String {
        let transcript = turns
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { turn in
                switch turn.role {
                case .user: return "Me: \(turn.text)"
                case .assistant: return "Local model: \(turn.text)"
                }
            }
            .joined(separator: "\n")

        return """
        I talked your last reply over with a small on-device model. That side conversation \
        is below for context — treat my lines as what I actually think and the local \
        model's as unverified scratch thinking.

        \(transcript)

        Pick this up from here.
        """
    }
}

// MARK: - Response text

/// Text cleanup for locally generated replies.
///
/// Separate from `SpokenText` (which prepares any text for the synthesizer):
/// this strips the artifacts *small local models* emit — reasoning blocks and
/// the "Sure! Here's..." preamble — before the text is either shown or spoken.
internal enum LocalReplyText {
    /// Remove reasoning blocks and leading filler, and collapse the markdown
    /// emphasis that a synthesizer would otherwise read as punctuation.
    internal static func clean(_ raw: String) -> String {
        var text = ThinkBlockFilter.stripAll(from: raw)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fillers = [
            "Sure! ", "Sure, ", "Of course! ", "Of course, ",
            "Certainly! ", "Certainly, ", "Great question! ", "Good question! "
        ]
        for filler in fillers where text.hasPrefix(filler) {
            text = String(text.dropFirst(filler.count))
        }
        return text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "##", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Suppresses `<think>…</think>` reasoning blocks from a *stream* of deltas.
///
/// Reasoning-by-default models (Qwen 3) are the best local option for actually
/// discussing a design, but they open with a long private monologue. It must
/// never reach the screen or the synthesizer, and it arrives token by token —
/// so this is a small state machine over the stream rather than a regex over
/// the finished text. `LocalReplyText.clean` handles the finished text too, for
/// the non-streaming path and as a backstop.
///
/// A partial tag straddling two deltas ("<thi" + "nk>") is held back rather
/// than emitted, which is why `feed` can return an empty string for a delta
/// that did contain characters.
internal struct ThinkBlockFilter {
    private static let open = "<think>"
    private static let close = "</think>"

    private var pending = ""
    private var insideThink = false

    internal init() {}

    /// Consume one delta, returning the text that is safe to display.
    internal mutating func feed(_ delta: String) -> String {
        pending += delta
        var visible = ""

        while !pending.isEmpty {
            if insideThink {
                guard let end = pending.range(of: Self.close) else {
                    // Keep only enough tail to recognize a split closing tag.
                    pending = String(pending.suffix(Self.close.count - 1))
                    return visible
                }
                pending = String(pending[end.upperBound...])
                insideThink = false
                continue
            }
            guard let start = pending.range(of: Self.open) else {
                // Emit everything except a tail that might be a partial tag.
                let holdback = Self.partialTagLength(in: pending, tag: Self.open)
                let emitCount = pending.count - holdback
                if emitCount > 0 {
                    visible += String(pending.prefix(emitCount))
                    pending = String(pending.suffix(holdback))
                }
                return visible
            }
            visible += String(pending[pending.startIndex..<start.lowerBound])
            pending = String(pending[start.upperBound...])
            insideThink = true
        }
        return visible
    }

    /// Flush whatever is held back at end of stream. A stream that ends inside
    /// a think block yields nothing, which is correct — that block was never
    /// meant to be seen.
    internal mutating func finish() -> String {
        defer {
            pending = ""
            insideThink = false
        }
        return insideThink ? "" : pending
    }

    /// How many trailing characters could still be the start of `tag`.
    private static func partialTagLength(in text: String, tag: String) -> Int {
        let maxOverlap = min(tag.count - 1, text.count)
        guard maxOverlap > 0 else { return 0 }
        for length in stride(from: maxOverlap, through: 1, by: -1) where text.hasSuffix(String(tag.prefix(length))) {
            return length
        }
        return 0
    }

    /// One-shot strip for text that is already complete.
    internal static func stripAll(from text: String) -> String {
        var filter = ThinkBlockFilter()
        let visible = filter.feed(text)
        return visible + filter.finish()
    }
}
