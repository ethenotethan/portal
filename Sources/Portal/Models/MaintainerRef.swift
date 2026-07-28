import Foundation

/// A reference to something that MAINTAINS a living artifact on an ongoing
/// basis — most importantly a Hermes cron job. Every living artifact is
/// *mutable* (any writer can upsert it), but only some are actively
/// *maintained*: tended on a schedule by a cron that keeps the data current.
/// That distinction is the whole point of this ref — it lets the UI say "a job
/// refreshes this every 6h" versus "written once, now orphaned".
///
/// Declared in the artifact content's top-level `maintainers` array so the
/// link travels with the artifact and survives id reuse:
/// ```json
/// {"id": "bkk-life", "maintainers": ["cron:job_abc"], "entities": {...}}
/// ```
/// The `type:value` shape leaves room for future maintainer kinds
/// (`session:`, `workflow:`) without a schema change; an unknown type parses
/// to `.other` so it round-trips on write but renders generically.
enum MaintainerRef: Equatable, Hashable, Identifiable {
    case cron(jobID: String)
    case other(type: String, value: String)

    var id: String { raw }

    /// The stored "type:value" string.
    var raw: String {
        switch self {
        case .cron(let jobID): return "cron:\(jobID)"
        case .other(let type, let value): return "\(type):\(value)"
        }
    }

    /// Parse "cron:job_abc". A bare string with no colon is treated as a cron
    /// job id — the common case, and what a human is likeliest to hand-type.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let colon = trimmed.firstIndex(of: ":") else {
            self = .cron(jobID: trimmed)
            return
        }
        let type = String(trimmed[trimmed.startIndex..<colon])
            .trimmingCharacters(in: .whitespaces).lowercased()
        let value = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        switch type {
        case "cron": self = .cron(jobID: value)
        default: self = .other(type: type, value: value)
        }
    }

    // MARK: - Content <-> refs

    /// Extract the top-level `maintainers` array from an artifact content body.
    /// Returns [] for non-JSON content (markdown docs) or a missing key.
    static func parseList(from content: String) -> [MaintainerRef] {
        guard let data = content.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = obj["maintainers"] as? [String] else { return [] }
        return raw.compactMap(MaintainerRef.init)
    }

    /// Write `refs` as the top-level `maintainers` array, returning the updated
    /// JSON. An empty list REMOVES the key (keeps clean bodies clean). De-dups
    /// preserving order. Returns nil when content isn't a JSON object — the
    /// caller must not offer maintainer editing on markdown artifacts.
    static func write(_ refs: [MaintainerRef], into content: String) -> String? {
        guard let data = content.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        if refs.isEmpty {
            obj.removeValue(forKey: "maintainers")
        } else {
            var seen = Set<String>()
            obj["maintainers"] = refs.map(\.raw).filter { seen.insert($0).inserted }
        }
        guard JSONSerialization.isValidJSONObject(obj),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let json = String(data: out, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
