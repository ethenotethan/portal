import Foundation

/// Recognizes the utterance that ends a local discussion and carries it forward:
/// "okay, let's submit", "send it", "go ahead", "continue".
///
/// This exists because the discussion is a *spoken* surface. Reaching for a
/// button to finish a hands-free conversation is the one moment the feature asks
/// the user to stop talking and start pointing, and it is exactly the moment they
/// have decided what they want — so the close-out has to be sayable.
///
/// A false positive spends a gateway turn on a half-finished thought, so the
/// matching is deliberately narrow: the *whole* utterance must reduce to a
/// close-out. Nothing is matched by substring, which is what keeps "go ahead and
/// explain why B is cheaper" a question rather than a submit. A false negative
/// just costs one more local turn, which is free.
internal enum LocalDiscussionCloseOut {

    /// Whether this utterance means "we're done talking, take it from here".
    internal static func isCloseOut(_ utterance: String) -> Bool {
        let core = normalize(utterance)
        guard !core.isEmpty else { return false }
        // Phrases that aren't verb-plus-object and so survive no stripping.
        if phrases.contains(core) { return true }
        var tokens = core.split(separator: " ").map(String.init)
        stripLeading(&tokens)
        stripTrailing(&tokens)
        // What survives must be close-out verbs and nothing but — chained is fine
        // ("go ahead and submit", "continue and send it"), because spoken
        // close-outs pile verbs up the way they pile softeners up. One content
        // word that isn't in these lists and the utterance is a question.
        guard tokens.contains(where: verbs.contains) else { return false }
        return tokens.allSatisfy { verbs.contains($0) || connective.contains($0) }
    }

    // MARK: - Normalization

    /// Lowercase, punctuation- and apostrophe-free, single-spaced. Dropping
    /// apostrophes is what makes one entry cover both "let's" and the "lets" a
    /// transcriber often produces.
    private static func normalize(_ utterance: String) -> String {
        // Apostrophes are dropped rather than spaced out: "let's" has to become
        // "lets", not "let s", or the contraction splits into two tokens neither of
        // which means anything.
        let folded = utterance.lowercased().filter { !apostrophes.contains($0) }
        let kept = folded.map { character -> Character in
            character.isLetter || character.isNumber || character == " " ? character : " "
        }
        return String(kept)
            .split(separator: " ", omittingEmptySubsequences: true)
            .filter { $0 != "just" }
            .joined(separator: " ")
    }

    /// Both the typed apostrophe and the one a transcriber emits.
    private static let apostrophes: Set<Character> = ["'", "\u{2019}"]

    /// Discourse markers and softeners that carry no intent of their own. Removed
    /// repeatedly, because spoken close-outs stack them: "ok cool, so let's go".
    private static let leading: Set<String> = [
        "ok", "okay", "okey", "alright", "right", "cool", "great", "perfect",
        "nice", "sweet", "awesome", "fine", "good", "yeah", "yea", "yep", "yup",
        "yes", "so", "and", "then", "well", "um", "uh", "but", "now", "please",
        "lets", "let", "us", "you", "can", "could", "would", "will"
    ]

    /// Objects and courtesies that trail the verb. Stripped from the tail so one
    /// verb entry covers "submit", "submit it", "send it to claude", "hand it over".
    private static let trailing: Set<String> = [
        "it", "that", "this", "them", "these", "those", "one",
        // "on" is absent on purpose: "go on" is how you ask for more, not less.
        "over", "off", "out", "up", "in", "to", "for", "with", "from",
        "the", "a", "my", "our", "claude", "agent", "prompt", "ask", "question",
        "session", "conversation", "chat", "turn", "work", "task", "message",
        "instruction", "instructions", "ahead", "along", "away", "through", "forward",
        "please", "thanks", "thank", "you", "now", "then", "already", "man",
        "dude", "buddy", "real"
    ]

    /// What may sit between chained verbs: the objects and softeners above, and
    /// the "and" that joins them.
    private static let connective: Set<String> = leading.union(trailing).union(["and"])

    /// The verbs that mean "hand this to the agent". `start` is deliberately
    /// absent: "start over" is how the user asks for the opposite.
    private static let verbs: Set<String> = [
        "submit", "send", "go", "do", "ship", "run", "continue", "proceed",
        "hand", "execute", "build", "post", "fire"
    ]

    /// Whole utterances that no amount of stripping reduces to a verb.
    private static let phrases: Set<String> = [
        "go for it", "go ahead", "take it from here", "make it so", "thats it",
        "thats the ask", "were good", "im good", "im done", "were done",
        "lets get to it", "off you go", "over to you", "your turn",
        "sounds like a plan", "thats the one", "thats what i want"
    ]

    private static func stripLeading(_ tokens: inout [String]) {
        while tokens.count > 1, let first = tokens.first, leading.contains(first) {
            tokens.removeFirst()
        }
    }

    private static func stripTrailing(_ tokens: inout [String]) {
        while tokens.count > 1, let last = tokens.last, trailing.contains(last) {
            tokens.removeLast()
        }
    }
}
