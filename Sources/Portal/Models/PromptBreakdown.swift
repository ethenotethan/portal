import SwiftUI

// MARK: - PromptSection

struct PromptSection: Identifiable, Codable {
    let id: String
    let name: String
    let source: String
    let contentPreview: String
    let fullContent: String
    let tokenCount: Int
    let charCount: Int
    let colorHex: String

    /// Computed Color from the hex string. Falls back to accent if invalid.
    var color: Color { Color(hex: colorHex) ?? .accentColor }

    /// Small sections (<500 chars) are expandable by default so the user sees the full content immediately.
    var isExpandableByDefault: Bool {
        fullContent.count < 500
    }
}

// MARK: - PromptBreakdown

struct PromptBreakdown: Codable {
    let sessionID: String
    let model: String
    let contextLimit: Int
    let totalSystemTokens: Int
    let sections: [PromptSection]
    let toolDefinitionsTokenCount: Int
    let toolDefinitionsCount: Int
    let conversationHistoryTokenCount: Int
    let conversationHistoryMessageCount: Int

    // MARK: Computed

    var totalUsedTokens: Int {
        totalSystemTokens + toolDefinitionsTokenCount + conversationHistoryTokenCount
    }

    var freeTokens: Int { contextLimit - totalUsedTokens }

    var utilizationPercent: Double {
        guard contextLimit > 0 else { return 0 }
        return Double(totalUsedTokens) / Double(contextLimit) * 100.0
    }

    var totalTokens: Int { totalUsedTokens }

    var contextUsagePercent: Double { utilizationPercent }

    var sortedSections: [PromptSection] {
        sections.sorted { $0.tokenCount > $1.tokenCount }
    }
}

// MARK: - Mock Data

extension PromptBreakdown {
    static func mock(sessionID: String) -> PromptBreakdown {
        PromptBreakdown(
            sessionID: sessionID,
            model: "deepseek/deepseek-v4-pro",
            contextLimit: 131_072,
            totalSystemTokens: 3100,
            sections: [
                PromptSection(
                    id: "persona",
                    name: "Persona",
                    source: "~/.hermes/personas/default.md",
                    contentPreview: "You are Portal Agent, an intelligent AI assistant created by Nous Research. You are helpful, knowledgeable, and direct. You assist...",
                    fullContent: "You are Portal Agent, an intelligent AI assistant created by Nous Research. You are helpful, knowledgeable, and direct. You assist...",
                    tokenCount: 800,
                    charCount: 472,
                    colorHex: "#7c7cff"
                ),
                PromptSection(
                    id: "memory",
                    name: "Memory",
                    source: "~/.hermes/memories/MEMORY.md",
                    contentPreview: "User prefers concise answers. Works primarily in Python and Swift. Has a background in machine learning and systems programming. F...",
                    fullContent: "User prefers concise answers. Works primarily in Python and Swift. Has a background in machine learning and systems programming. F...",
                    tokenCount: 400,
                    charCount: 218,
                    colorHex: "#4ecdc4"
                ),
                PromptSection(
                    id: "user-profile",
                    name: "User Profile",
                    source: "~/.hermes/memories/USER.md",
                    contentPreview: "OS: macOS 26.3\nHome directory: /Users/inference2\nCurrent working directory: /Users/inference2/.hermes/hermes-agent\nShell: zsh",
                    fullContent: "OS: macOS 26.3\nHome directory: /Users/inference2\nCurrent working directory: /Users/inference2/.hermes/hermes-agent\nShell: zsh\n...",
                    tokenCount: 200,
                    charCount: 152,
                    colorHex: "#ff6b6b"
                ),
                PromptSection(
                    id: "ephemeral-prompt",
                    name: "Ephemeral Prompt",
                    source: "(session.set_prompt)",
                    contentPreview: "Current date: Wednesday, June 03, 2026\nActive conversation context: discussing prompt assembly visualizer implementation for Herm...",
                    fullContent: "Current date: Wednesday, June 03, 2026\nActive conversation context: discussing prompt assembly visualizer implementation for Herm...",
                    tokenCount: 500,
                    charCount: 245,
                    colorHex: "#ffe66d"
                ),
                PromptSection(
                    id: "active-skills",
                    name: "Active Skills",
                    source: "(session.attach_skills)",
                    contentPreview: "# Active Skills\n\n- **swift-codebase**: Navigate and understand Swift/SwiftUI codebases. Provides guidance on project structure, ...",
                    fullContent: "# Active Skills\n\n- **swift-codebase**: Navigate and understand Swift/SwiftUI codebases. Provides guidance on project structure, ...",
                    tokenCount: 1200,
                    charCount: 498,
                    colorHex: "#a8e6cf"
                )
            ],
            toolDefinitionsTokenCount: 2800,
            toolDefinitionsCount: 43,
            conversationHistoryTokenCount: 4500,
            conversationHistoryMessageCount: 14
        )
    }

    static var mock: PromptBreakdown {
        mock(sessionID: "mock-session-001")
    }
}
