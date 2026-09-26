import Foundation

/// The two texts the dock hands the agent: an ephemeral system prompt that
/// tells it which page it is standing on and what the user may ask of it, and a
/// priming message that makes it load the page's context with its tools before
/// the user says a word. Pure string rendering, deterministic for a context.
internal enum PageIntentPrompt {
    /// The ephemeral system prompt (`session.set_prompt`): appended to the
    /// agent's system prompt for every turn of this session, never persisted.
    internal static func system(for context: PageIntentContext) -> String {
        var lines: [String] = [
            "You are operating for the Portal desktop app, attached to one of its pages: \(context.title).",
            "The user opened a voice/chat dock on that page. Speech is transcribed, so input may be terse, unpunctuated or cut short;",
            "ask one short clarifying question when an instruction is genuinely ambiguous, otherwise act.",
            "",
            "Current page state:",
        ]
        lines += context.stateLines.map { "- \($0)" }
        lines += [
            "",
            "What the user may do here:",
            "- Ask questions about what is on the page: answer from the context you loaded, naming the page, node or file you read.",
            "- Dispatch work: do it with your tools and report the outcome plainly. Do not describe a plan when you can execute it.",
            "- Edits to wiki pages go through the wiki write path with `if_match` set to the page's current `updated` value, so a stale write is refused rather than overwriting.",
            "- Cron changes go through `cron.manage` (describe first, then update); never edit job files by hand.",
            "- When the page state above changes, this prompt is refreshed; trust the latest state over earlier turns.",
            "",
            "Keep spoken replies short: one or two sentences the user can listen to, with detail only when asked.",
        ]
        return lines.joined(separator: "\n")
    }

    /// The first user message the dock submits on open, so the session already
    /// holds the page's context when the user starts talking.
    internal static func priming(for context: PageIntentContext) -> String {
        var lines = ["Load the context for this page now (\(context.title)):"]
        if context.preloadSteps.isEmpty {
            lines.append("- Nothing specific is selected; load an overview of the page with your tools.")
        } else {
            lines += context.preloadSteps.enumerated().map { "\($0.offset + 1). \($0.element)" }
        }
        lines.append("Then confirm in one line what you have loaded and wait for the user.")
        return lines.joined(separator: "\n")
    }
}
