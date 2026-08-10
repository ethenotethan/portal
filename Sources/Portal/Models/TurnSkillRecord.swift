import Foundation

/// How a skill came to shape a turn.
///
/// Skills reach the agent by two genuinely different routes, and conflating them
/// makes the attribution misleading. `attached` skills were chosen by the user
/// before the turn was sent (`/graphify` → `ChatViewModel.activeSkills` → the
/// SKILL.md text is prepended to the outgoing prompt). `loaded` skills were
/// pulled in by the agent *during* the turn, by calling the gateway's
/// `skill_view` tool — the app doesn't choose those and can't know them until
/// they happen.
///
/// The distinction matters when reading history: "I asked for this skill" and
/// "the model decided it needed this skill" are different facts about the turn.
internal enum TurnSkillOrigin: String, Codable, Equatable, CaseIterable {
    /// Attached by the user before the prompt was sent; SKILL.md was prepended.
    case attached
    /// Read by the agent mid-turn via the `skill_view` tool.
    case loaded
}

/// One skill's participation in one turn, durable enough to survive a session
/// switch and an app relaunch.
///
/// Deliberately a flat value rather than a `SkillInfo` reference: the catalog is
/// mutable (skills get renamed, edited, archived by the curator), and a turn's
/// record is a historical claim about what happened. Storing the name and
/// category directly means a past turn keeps reading correctly after the
/// underlying skill changes or disappears.
internal struct TurnSkillRecord: Identifiable, Codable, Equatable {
    /// Skill name as it was known at the time of the turn.
    internal let name: String
    /// Category for the chip color/grouping. "general" when unknown — dynamic
    /// loads only carry a name, so the category is resolved from the catalog
    /// when possible and falls back rather than guessing.
    internal let category: String
    internal let origin: TurnSkillOrigin

    /// Identity is name + origin: the same skill can legitimately appear twice
    /// in a turn — attached up front AND re-read by the agent — and those are
    /// two true statements, not a duplicate.
    internal var id: String { "\(origin.rawValue):\(name)" }

    internal init(name: String, category: String = "general", origin: TurnSkillOrigin) {
        self.name = name
        self.category = category.isEmpty ? "general" : category
        self.origin = origin
    }

    /// Record for a user-attached skill, carrying the catalog's category.
    internal static func attached(_ skill: SkillInfo) -> TurnSkillRecord {
        TurnSkillRecord(name: skill.name, category: skill.category, origin: .attached)
    }
}

extension TurnSkillRecord {
    /// The `skill_view` tool's display label, reduced to the skill name.
    ///
    /// The gateway sends a rendered label rather than raw arguments on
    /// `tool.start` (`_tool_ctx` → `build_tool_label`), so the skill name has to
    /// be read back out of it. For `skill_view` that label is built by
    /// `agent/display.py` as either the bare skill name or `"<name> → <path>"`
    /// when a linked reference/template/script is being read. Friendly labels
    /// can also be disabled host-side, in which case the preview may arrive as
    /// `name=graphify` style raw args — handled here so attribution doesn't
    /// silently depend on a host display setting.
    ///
    /// Returns nil when nothing name-shaped survives, so a tool call the app
    /// can't attribute is skipped rather than recorded as a skill named "".
    internal static func skillName(fromViewLabel label: String) -> String? {
        // A linked-file read reports "<skill> → references/api.md"; the skill is
        // the part before the arrow.
        var candidate = label
        if let arrow = candidate.range(of: "→") {
            candidate = String(candidate[candidate.startIndex..<arrow.lowerBound])
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Raw-args form (friendly labels off): name=graphify, other=…
        if candidate.contains("=") {
            let fields = candidate.split(separator: ",")
            for field in fields {
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2,
                      parts[0].trimmingCharacters(in: .whitespaces) == "name" else { continue }
                candidate = parts[1].trimmingCharacters(in: .whitespaces)
                break
            }
        }

        // Strip quoting the raw-args form may carry, and any truncation ellipsis
        // the gateway added to fit its 80-char preview budget.
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        while candidate.hasSuffix("…") || candidate.hasSuffix("...") {
            candidate = candidate.hasSuffix("…")
                ? String(candidate.dropLast())
                : String(candidate.dropLast(3))
            candidate = candidate.trimmingCharacters(in: .whitespaces)
        }

        return candidate.isEmpty ? nil : candidate
    }
}

extension Array where Element == TurnSkillRecord {
    /// Merge a record in, keeping the first occurrence.
    ///
    /// Ordering is arrival order (attached skills first, since they precede the
    /// turn; then dynamic loads in the order the agent read them), which reads
    /// as the turn's actual narrative.
    internal mutating func appendSkillRecord(_ record: TurnSkillRecord) {
        guard !contains(where: { $0.id == record.id }) else { return }
        append(record)
    }
}
