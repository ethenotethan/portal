import Foundation

/// How the agent should shape its answers — from full topological analysis
/// down to plain conversational prose. Composed with the app formatting
/// prompt into the session's ephemeral system prompt, so it can be changed
/// per session without touching the gateway persona.
enum ResponseStyle: String, CaseIterable, Codable, Identifiable {
    /// Diagram-first, richly structured analysis (the app's original behavior).
    case deepMap = "deep"
    /// Structure only where it earns its keep; answer first, detail after.
    case balanced = "balanced"
    /// Concise conversational prose; no diagrams or sections unless asked.
    case direct = "direct"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deepMap: "Deep Map"
        case .balanced: "Balanced"
        case .direct: "Direct"
        }
    }

    var icon: String {
        switch self {
        case .deepMap: "point.3.connected.trianglepath.dotted"
        case .balanced: "slider.horizontal.3"
        case .direct: "text.alignleft"
        }
    }

    var help: String {
        switch self {
        case .deepMap: "Full structural analysis — diagrams, headings, tables"
        case .balanced: "Structure only where it helps; answer first"
        case .direct: "Short conversational answers, no diagrams"
        }
    }

    /// Style instructions appended to the app formatting prompt.
    var preamble: String {
        switch self {
        case .deepMap:
            """
            ## Response Style: Deep Map
            Build comprehensive, structured analyses that surface the mental model and shape of the answer. \
            Prefer diagram-first: when a visual explanation is possible, lead with the Mermaid diagram, then \
            explain in prose. Use headings and tables to expose the topology of the topic.
            """
        case .balanced:
            """
            ## Response Style: Balanced
            Lead with the direct answer in the first paragraph, then supporting detail. Match depth to the \
            question: include a diagram or table only when it genuinely clarifies structure, not by default. \
            Keep headings for genuinely long answers.
            """
        case .direct:
            """
            ## Response Style: Direct
            Answer directly and concisely in conversational prose. Lead with the answer in the first sentence. \
            Do not use Mermaid diagrams, headings, or tables unless the user explicitly asks for them. \
            Prefer a few short paragraphs or a brief list.
            """
        }
    }

    /// One-message override injected by the `/brief` command — applies the
    /// direct style to a single reply without changing the session style.
    static let briefOverridePreamble = """
    (For this reply only: answer directly and concisely in prose. Lead with the answer in the \
    first sentence. No diagrams, headings, or tables unless explicitly requested.)
    """

    // MARK: - Stored default

    static let userDefaultsKey = "defaultResponseStyle"

    /// Style for new sessions — the last style the user picked anywhere.
    /// Defaults to deepMap, the app's original behavior.
    static var storedDefault: ResponseStyle {
        get {
            UserDefaults.standard.string(forKey: userDefaultsKey)
                .flatMap(ResponseStyle.init(rawValue:)) ?? .deepMap
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }
}
