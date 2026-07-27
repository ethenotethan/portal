import SwiftUI

/// The "what capability" lens: the skills active for the current turn, shown as
/// the taxonomy they self-organize into (grouped by `category`), pinned to the
/// far-right of the streaming plane beside the running-tools trace.
///
/// It's the sibling of the timeline ("when" — tool bars) and the file tree
/// ("where" — files touched): this answers "what capability is loaded." The
/// source is `ChatViewModel.activeSkills` — the skills whose SKILL.md is
/// prepended to the turn's prompt — so it's honest ("skills active", not
/// "skills invoked") and updates live as skills attach/detach, since the host
/// observes that published list.
internal struct TurnSkillsLens: View {
    /// Skills active for this turn (from `ChatViewModel.activeSkills`).
    internal let skills: [SkillInfo]

    /// Skills bucketed by their category taxonomy, categories in stable
    /// (alphabetical) order and skills alphabetical within each — deterministic
    /// so the cluster doesn't reshuffle as unrelated state changes.
    private var groups: [(category: String, skills: [SkillInfo])] {
        Dictionary(grouping: skills, by: { $0.category.isEmpty ? "general" : $0.category })
            .map { (category: $0.key, skills: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.category < $1.category }
    }

    /// One category is the common case (most local skills are "general"); only
    /// then do we drop the per-category headers and show a flat chip list.
    private var isFlat: Bool { groups.count <= 1 }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            if isFlat {
                ForEach(skills.sorted { $0.name < $1.name }) { skill in
                    chip(skill.name, category: skill.category)
                }
            } else {
                ForEach(groups, id: \.category) { group in
                    categoryBlock(group.category, group.skills)
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

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.accent)
            Text("Skills")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 0)
            Text("\(skills.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func categoryBlock(_ category: String, _ skills: [SkillInfo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(Self.color(for: category))
                    .frame(width: 5, height: 5)
                Text(category.uppercased())
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
            }
            ForEach(skills) { skill in
                chip(skill.name, category: category)
            }
        }
    }

    private func chip(_ name: String, category: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Self.color(for: category))
                .frame(width: 3)
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(Self.color(for: category).opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
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
