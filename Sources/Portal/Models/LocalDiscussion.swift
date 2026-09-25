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

/// A spoken side-conversation with the on-device model.
///
/// It runs in one of two directions. *Backwards*, anchored to an assistant
/// reply: its text — plus the options it offered, when the reasoning summarizer
/// found any — becomes the model's grounding, so "why B?" resolves against the
/// actual reply instead of thin air. *Forwards*, from the composer with no reply
/// yet: the user talks through what they are about to ask for, and the grounding
/// is their draft plus a briefing on the other sessions, so "what are we working
/// on today?" has an answer.
///
/// Either way the discussion is scratch space: it costs no gateway tokens, never
/// appears in `ChatViewModel.messages`, and is thrown away on end unless the
/// user explicitly takes its conclusion forward.
internal struct LocalDiscussion: Identifiable, Equatable, Sendable {
    /// The anchor message's id, so a second "discuss" tap on the same message
    /// resumes rather than duplicates. A composer-started discussion gets a
    /// fresh id, which is what keeps it from colliding with any message.
    internal let id: UUID
    /// The anchor reply, already trimmed to a context budget the small local
    /// models can actually attend to (see `Self.anchorBudget`). Empty when the
    /// discussion was started from the composer, before any reply exists.
    internal let anchorText: String
    /// What the user has typed but not sent — the "here's a design, let's talk
    /// about it" case. Trimmed to the same budget as an anchor.
    internal let draftText: String
    /// Options the anchor offered ("Reply A, B, or C"), when a reasoning
    /// summary made them explicit. Empty is normal and fine.
    internal let options: [String]
    /// What else is open on this machine. Lets the model answer about the work
    /// rather than only about the text in front of it.
    internal let briefing: LocalDiscussionBriefing
    internal var turns: [LocalDiscussionTurn]
    /// The exchange the model can no longer remember on its own — everything said
    /// before this discussion was set aside and picked up again.
    ///
    /// Continuity normally comes for free from the engine's live chat session, but
    /// that session is dropped whenever the discussion closes or another one runs.
    /// Resuming therefore has to re-state the exchange in the prompt, and it is
    /// frozen at resume time rather than tracking `turns`, because `instructions()`
    /// must stay byte-identical across the exchange for the KV cache to survive
    /// from one turn to the next.
    internal private(set) var recap: [LocalDiscussionTurn]

    /// How much of the anchor reply is handed to the model. A 1-4B model given
    /// 8k characters of context answers about the middle of it; the head is
    /// where the claim being discussed almost always is.
    internal static let anchorBudget = 1_600

    internal init(
        anchorID: UUID,
        anchorText: String = "",
        draftText: String = "",
        options: [String] = [],
        briefing: LocalDiscussionBriefing = .empty,
        turns: [LocalDiscussionTurn] = [],
        recap: [LocalDiscussionTurn] = []
    ) {
        self.id = anchorID
        self.anchorText = Self.trimAnchor(anchorText)
        self.draftText = Self.trimAnchor(draftText)
        self.options = options
        self.briefing = briefing
        self.turns = turns
        self.recap = recap
    }

    /// Whether this discussion is about a reply that already exists, as opposed
    /// to one the user is still working out how to ask for.
    internal var isAnchored: Bool { !anchorText.isEmpty }

    /// Whether there's anything worth handing back to the agent.
    internal var hasExchange: Bool {
        turns.contains { $0.role == .assistant && !$0.text.isEmpty }
    }

    /// Index in `turns` of the first thing said since this discussion was picked
    /// up again, or nil when it is all one sitting.
    ///
    /// Purely for display: a resumed thread reads as one continuous exchange, which
    /// is right for the model but hides from the user the seam where they left off
    /// and came back. Nil while nothing new has been said yet, because a marker
    /// pointing at the very end of the thread marks nothing.
    internal var resumedAt: Int? {
        guard !recap.isEmpty, turns.count > recap.count else { return nil }
        return recap.count
    }

    /// This discussion, ready to be picked up where it left off: everything said
    /// so far moves into the prompt, since the engine's own memory of it is gone.
    internal func resuming() -> LocalDiscussion {
        guard !turns.isEmpty else { return self }
        var resumed = self
        resumed.recap = turns
        return resumed
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
    /// gibberish — "asterisk asterisk"), and honesty — it can see what is written
    /// into this prompt and nothing else, so it must decline rather than invent
    /// repo details.
    ///
    /// The context that follows the instructions is whatever the discussion has:
    /// a session briefing, the draft being worked on, the reply being discussed.
    /// A composer-started discussion often has only the briefing, and that is the
    /// point of the briefing — "what are we working on today?" used to be
    /// unanswerable by construction.
    internal func instructions() -> String {
        var prompt = """
        You are a thinking partner in a SPOKEN conversation. The user is an experienced \
        engineer talking out loud with you\(situation).

        How to answer:
        - You are being read aloud by a speech synthesizer. Answer in one to three short \
        sentences. No markdown, no bullet lists, no code blocks, no headings.
        - Ground every answer in the context below. Use the sessions' own names and the \
        text's own words when it helps.
        - The context below is ALL you can see — you cannot open files, run commands, read \
        code, or look up history. If a question needs something that isn't here, say what \
        you'd need to know instead of guessing at specifics.
        - Skip preamble, apologies, and flattery. Answer the question, then stop.
        - Take a position when asked for one. "Both are reasonable" is not an answer.
        - This conversation has a destination: when they are satisfied, its conclusion \
        is handed to the coding agent as an instruction. Help them converge on one.
        """
        prompt += purpose

        if let sessions = briefing.promptBlock {
            prompt += """


            \(sessions)
            """
        }

        if !options.isEmpty {
            let list = options.enumerated()
                .map { index, option in "  \(index + 1). \(option)" }
                .joined(separator: "\n")
            prompt += """


            The reply offered these options:
            \(list)
            """
        }

        if isAnchored {
            prompt += """


            The reply under discussion:
            \"\"\"
            \(anchorText)
            \"\"\"
            """
        }

        if !draftText.isEmpty {
            prompt += """


            What they have drafted so far but NOT yet sent to the agent:
            \"\"\"
            \(draftText)
            \"\"\"
            """
        }

        if !recap.isEmpty {
            prompt += """


            Earlier in this same conversation, before it was set aside:
            \(transcript(of: recap))

            Continue from there. Do not greet them again or restate what was already settled.
            """
        }
        return prompt
    }

    /// The clause that tells the model which conversation it is in. Getting this
    /// wrong is what made a composer-started discussion answer as though a reply
    /// it cannot see were the subject.
    private var situation: String {
        isAnchored
            ? " about a reply they just received from a coding agent. The reply is quoted below"
            : " before they ask a coding agent to do anything"
    }

    /// What the user is trying to get out of the exchange, which differs by
    /// direction: understanding a reply versus deciding what to ask for.
    private var purpose: String {
        if isAnchored {
            return """

            - Discuss what is actually in the reply. Do not re-plan work they didn't ask about.
            """
        }
        return """

        - They are working out what to ask the agent for next. Help them shape and sharpen \
        that ask; do not try to do the work yourself.
        - If they ask what they are working on, answer from the session list — name the \
        threads and say where each one stopped. Do not claim to know more about a session \
        than its line says.
        """
    }

    // MARK: - Drafting the ask

    /// The sentinel the drafting pass emits when the conversation never landed on
    /// anything to do. Cheaper than trying to detect a non-answer in prose, and it
    /// lets the handoff fall back to the transcript rather than shipping a
    /// confident instruction nobody agreed to.
    internal static let noAskSentinel = "NOTHING SETTLED"

    /// A drafted ask longer than this stopped being an instruction and started
    /// being the model re-writing the conversation.
    internal static let draftedAskBudget = 1_200

    /// Instructions for the one-shot pass that turns the exchange into the actual
    /// instruction for the agent.
    ///
    /// A separate prompt from `instructions()`, not a final question in the same
    /// exchange, for two reasons: the discussion's rules are tuned for *speech* —
    /// one to three sentences, no markdown — which is wrong for a written prompt,
    /// and the differing text is what makes the engine build a clean session
    /// instead of continuing in the voice it has been using all along.
    internal func draftingInstructions() -> String {
        """
        You convert a side conversation into ONE written instruction for a coding agent.

        Rules:
        - Output the instruction and nothing else. No preamble, no sign-off, no \
        markdown, no headings, no quotes around it, no options list.
        - Address the agent directly, in the imperative. One to four sentences.
        - Write only what the conversation actually settled on. Never invent file \
        names, APIs, commands, or steps that were not discussed.
        - Prefer the conversation's own words for anything specific.
        - If the conversation reached no decision and no request, output exactly: \
        \(Self.noAskSentinel)
        """
    }

    /// The exchange, handed to the drafting pass with whatever grounding it had.
    internal func draftingPrompt() -> String {
        var prompt = ""
        if isAnchored {
            prompt += """
            The reply we were discussing:
            \"\"\"
            \(anchorText)
            \"\"\"


            """
        }
        if !draftText.isEmpty {
            prompt += """
            What I had already drafted for the agent:
            \"\"\"
            \(draftText)
            \"\"\"


            """
        }
        // `turns` is the whole thread, recapped turns included — adding `recap` to it
        // would hand the model the first sitting twice.
        prompt += """
        The conversation ("Me" is the engineer, "Local model" is you):
        \(transcript(of: turns))


        Write the single instruction the engineer wants the agent to carry out now.
        """
        return prompt
    }

    /// A drafted ask, or nil when the pass declined or ran away with itself.
    internal static func usableAsk(_ raw: String) -> String? {
        var text = LocalReplyText.clean(raw)
        // Small models like to wrap the answer in quotes despite being told not to.
        while let first = text.first, let last = text.last,
              first == last, first == "\"" || first == "'", text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty, text.count <= draftedAskBudget else { return nil }
        guard !text.uppercased().contains(noAskSentinel) else { return nil }
        return text
    }

    // MARK: - Handoff

    /// The prompt that hands the discussion's conclusion back to the real agent.
    ///
    /// The point of the feature: talk it out locally for free, then spend one
    /// gateway turn on the decision you actually reached. So the drafted `ask`
    /// leads — that is the output the whole conversation was for — and the
    /// exchange follows as the reasoning behind it, labelled by speaker so the
    /// agent weighs the local model's side as scratch thinking rather than as
    /// prior instruction from the user.
    ///
    /// With no usable `ask` (the pass declined, or generation failed) the
    /// transcript stands on its own, as it did before there was a drafting pass —
    /// worse to read, but nothing is lost.
    ///
    /// A composer-started discussion carries the draft into the prompt, because
    /// otherwise submitting the conversation would silently eat the design the
    /// user had pasted there.
    internal func handoffPrompt(ask: String? = nil) -> String {
        let opening = isAnchored
            ? "I talked your last reply over with a small on-device model."
            : "Before asking you for anything, I talked this through with a small on-device model."
        var draft = ""
        if !isAnchored, !draftText.isEmpty {
            draft = """


            What I had drafted going in:
            \"\"\"
            \(draftText)
            \"\"\"
            """
        }
        let context = """
        \(opening) That side conversation is below for context — treat my lines as what I \
        actually think and the local model's as unverified scratch thinking.\(draft)

        \(transcript(of: turns))
        """

        guard let ask, !ask.isEmpty else {
            return context + "\n\nPick this up from here."
        }
        return """
        \(ask)

        \(context)
        """
    }

    /// Turns, one per line, attributed. Shared by the resume grounding, the
    /// drafting pass, and the handoff, which all need the same shape.
    private func transcript(of turns: [LocalDiscussionTurn]) -> String {
        turns
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { turn in
                switch turn.role {
                case .user: return "Me: \(turn.text)"
                case .assistant: return "Local model: \(turn.text)"
                }
            }
            .joined(separator: "\n")
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
