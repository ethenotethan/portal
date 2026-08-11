import SwiftUI

/// The "what capability" lens: the skills that shaped a turn, pinned to the
/// far-right of the streaming plane beside the running-tools trace.
///
/// It's the sibling of the timeline ("when" — tool bars) and the file tree
/// ("where" — files touched): this answers "what capability was in play."
///
/// Grouped by *origin* rather than by category, because origin is the fact that
/// was previously missing: a skill the user attached with `/name` and a skill the
/// agent decided to read mid-turn are different events, and only the first was
/// ever visible. Category survives as the chip color, so the taxonomy still
/// reads at a glance without a second axis of headers.
internal struct TurnSkillsLens: View {
    /// Skills recorded for this turn — live for the in-flight turn, replayed
    /// from `ChatMessage.skills` for past ones.
    internal let skills: [TurnSkillRecord]

    /// Origins in a fixed order (attached first — it precedes the turn), each
    /// with its skills alphabetized so the cluster doesn't reshuffle as
    /// unrelated state changes.
    private var groups: [(origin: TurnSkillOrigin, skills: [TurnSkillRecord])] {
        TurnSkillOrigin.allCases.compactMap { origin in
            let matching = skills.filter { $0.origin == origin }.sorted { $0.name < $1.name }
            return matching.isEmpty ? nil : (origin: origin, skills: matching)
        }
    }

    /// With only one origin present the header would be the only thing
    /// distinguishing it, and the section label already says which — so a single
    /// group renders flat.
    private var isFlat: Bool { groups.count <= 1 }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if isFlat {
                ForEach(skills.sorted { $0.name < $1.name }) { skill in
                    chip(skill)
                }
            } else {
                ForEach(groups, id: \.origin) { group in
                    originBlock(group.origin, group.skills)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    /// Names the single origin when there is only one ("Skills attached" /
    /// "Skills loaded"), so the flat list still says how the skills got there.
    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.accent)
            Text(isFlat ? (groups.first.map { "Skills \($0.origin.rawValue)" } ?? "Skills") : "Skills")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            Text("\(skills.count)")
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func originBlock(_ origin: TurnSkillOrigin, _ skills: [TurnSkillRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: Self.icon(for: origin))
                    .font(.system(size: 7))
                    .foregroundStyle(Theme.tertiary)
                Text(Self.label(for: origin).uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            ForEach(skills) { skill in
                chip(skill)
            }
        }
    }

    private func chip(_ skill: TurnSkillRecord) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.color(for: skill.category))
                .frame(width: 3)
            Text(skill.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            // Only agent-loaded skills carry a marker: attached is the default
            // reading, and badging both would be noise on every chip.
            if skill.origin == .loaded {
                Image(systemName: Self.icon(for: .loaded))
                    .font(.system(size: 7))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Self.color(for: skill.category).opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
        .help(Self.tooltip(for: skill))
    }

    private static func label(for origin: TurnSkillOrigin) -> String {
        switch origin {
        case .attached: return "attached"
        case .loaded: return "agent-loaded"
        }
    }

    private static func icon(for origin: TurnSkillOrigin) -> String {
        switch origin {
        case .attached: return "paperclip"
        case .loaded: return "sparkles"
        }
    }

    private static func tooltip(for skill: TurnSkillRecord) -> String {
        switch skill.origin {
        case .attached:
            return "\(skill.name) — attached before this turn; its instructions were included in the prompt."
        case .loaded:
            return "\(skill.name) — the agent read this skill itself during the turn."
        }
    }

    /// Stable per-category color from a small palette (hash the name → index),
    /// so the same category reads the same hue across turns without a lookup
    /// table we'd have to keep in sync with the skill catalog.
    private static func color(for category: String) -> Color {
        let palette: [Color] = [
            Theme.graphSearch, Theme.graphRead, Theme.graphWrite,
            Theme.graphPatch, Theme.graphTerminal, Theme.agentAccent, Theme.graphReasoning
        ]
        var hash: UInt64 = 1469598103934665603   // FNV-1a offset basis
        for byte in category.lowercased().utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return palette[Int(hash % UInt64(palette.count))]
    }
}
