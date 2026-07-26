import Foundation

/// A concrete external thing that MORE THAN ONE tool call in a turn interacts
/// with — a K8s pod, a URL/host, a database table — detected deterministically
/// from tool-call context text (no model reasoning; pure pattern matching, so
/// it never hallucinates). Drawn as a labeled shape on the timeline with edges
/// to each bar that touched it, so "these three kubectl calls all hit
/// pod/api-server" becomes visible connectivity instead of scattered bars.
///
/// Files are deliberately NOT here — they live in the file-tree lens; this is
/// the non-file, stateful-target overlay.
internal struct SharedEntity: Identifiable {
    internal enum Kind: String {
        case k8sPod = "K8s pod"
        case k8sService = "K8s service"
        case k8sDeployment = "K8s deployment"
        case url = "URL"
        case host = "Host"
        case dbTable = "DB table"
        case container = "Container"

        /// SF Symbol for the entity shape.
        internal var icon: String {
            switch self {
            case .k8sPod, .k8sDeployment, .container: return "shippingbox"
            case .k8sService: return "network"
            case .url, .host: return "globe"
            case .dbTable: return "cylinder"
            }
        }
    }

    internal let kind: Kind
    /// The resource name / target ("api-server", "example.com", "users").
    internal let label: String
    /// Thought-graph node ids that touched this entity (≥2 by construction).
    internal let nodeIDs: [String]

    /// Stable identity: kind + normalized label.
    internal var id: String { "\(kind.rawValue):\(label.lowercased())" }

    /// Full display label for the shape ("K8s pod · api-server").
    internal var displayLabel: String { "\(kind.rawValue) · \(label)" }
}

/// Deterministic detection of shared external entities across a turn's nodes.
/// Each detector is a narrow, high-precision pattern — we would rather MISS an
/// entity than invent one, so the overlay only ever draws real, matched things.
internal enum SharedEntityExtractor {

    /// One (kind, label) reference found in a node's context, plus the node.
    private struct Ref { let kind: SharedEntity.Kind; let label: String; let nodeID: String }

    internal static func extract(from nodes: [ThoughtGraphNode]) -> [SharedEntity] {
        var refs: [Ref] = []
        for node in nodes {
            guard let ctx = node.context, !ctx.isEmpty else { continue }
            refs.append(contentsOf: detect(in: ctx, nodeID: node.id))
        }
        // Group by (kind, normalized label); keep only entities >1 node touches
        // (a single-touch entity isn't "shared" — nothing to connect).
        var byKey: [String: (kind: SharedEntity.Kind, label: String, ids: [String])] = [:]
        var order: [String] = []
        for ref in refs {
            let key = "\(ref.kind.rawValue):\(ref.label.lowercased())"
            if byKey[key] == nil {
                byKey[key] = (ref.kind, ref.label, [])
                order.append(key)
            }
            // Dedup node ids — one node mentioning the entity twice counts once.
            if byKey[key]?.ids.contains(ref.nodeID) == false {
                byKey[key]?.ids.append(ref.nodeID)
            }
        }
        return order.compactMap { key in
            guard let e = byKey[key], e.ids.count >= 2 else { return nil }
            return SharedEntity(kind: e.kind, label: e.label, nodeIDs: e.ids)
        }
    }

    // MARK: - Detectors

    private static func detect(in ctx: String, nodeID: String) -> [Ref] {
        var found: [Ref] = []
        for (kind, regex, group) in Self.patterns {
            let ns = ctx as NSString
            let matches = regex.matches(in: ctx, range: NSRange(location: 0, length: ns.length))
            for m in matches where m.numberOfRanges > group && m.range(at: group).location != NSNotFound {
                let label = ns.substring(with: m.range(at: group)).trimmingCharacters(in: .whitespaces)
                guard !label.isEmpty else { continue }
                found.append(Ref(kind: kind, label: label, nodeID: nodeID))
            }
        }
        return found
    }

    /// (kind, pattern source, capture-group index). High-precision only.
    /// Compiled once by `patterns`; a malformed literal drops out (and fails
    /// the extractor tests) rather than crashing at call time.
    private static let patternSources: [(SharedEntity.Kind, String, Int)] = [
        // kubectl … pod[/ ]<name>  (also svc/service, deployment/deploy)
        (.k8sPod, #"\bpods?[/ ]([a-z0-9][a-z0-9\-.]{1,60})"#, 1),
        (.k8sService, #"\b(?:svc|services?)[/ ]([a-z0-9][a-z0-9\-.]{1,60})"#, 1),
        (.k8sDeployment, #"\b(?:deploy|deployments?)[/ ]([a-z0-9][a-z0-9\-.]{1,60})"#, 1),
        // http(s)://host[/path] → capture the host as the entity.
        (.host, #"https?://([a-z0-9.\-]+\.[a-z]{2,})"#, 1),
        // Conservative container names: `container <name>` / `--name <name>`.
        (.container, #"(?:container|--name)[= ]([a-z0-9][a-z0-9_\-.]{1,60})"#, 1),
    ]

    private static let patterns: [(SharedEntity.Kind, NSRegularExpression, Int)] = {
        patternSources.compactMap { kind, source, group in
            do {
                let regex = try NSRegularExpression(pattern: source, options: .caseInsensitive)
                return (kind, regex, group)
            } catch {
                assertionFailure("SharedEntity pattern failed to compile: \(source)")
                return nil
            }
        }
    }()
}
