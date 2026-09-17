import Foundation

// MARK: - GraphSurface

/// Which graph the **Graphs** section is showing.
///
/// Portal has two graphs that answer different questions about the same
/// harness, and they used to live in unrelated places — the knowledge graph
/// behind the old top-level "Wiki" door, and the cron dataflow graph buried in
/// the Cron Activity surface. They are now siblings under one door, chosen by
/// the dropdown that replaced the "Wiki" title.
///
/// The raw values are persisted (the section reopens on the graph you left it
/// on), so they are part of the stored contract: rename the labels freely, but
/// not the cases.
internal enum GraphSurface: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The wiki knowledge graph — pages and the links between them.
    case wiki
    /// The cron dataflow graph — jobs and the data they read, write, deliver.
    case runtime

    internal var id: String { rawValue }

    /// Menu title. "Runtime graph" rather than "Dataflow" because the pairing is
    /// what disambiguates: one graph is what the harness *knows*, the other is
    /// what it *does*.
    internal var label: String {
        switch self {
        case .wiki: return "Wiki"
        case .runtime: return "Runtime graph"
        }
    }

    /// One line under the label in the dropdown, so the choice doesn't rely on
    /// the reader already knowing which graph is which.
    internal var summary: String {
        switch self {
        case .wiki: return "Pages and the links between them"
        case .runtime: return "Jobs and the data they read, write, and deliver"
        }
    }

    internal var systemImage: String {
        switch self {
        case .wiki: return "network"
        case .runtime: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// Tolerant decode for the persisted `@AppStorage` string: an unknown or
    /// empty value (a downgrade, or a hand-edited defaults plist) opens the wiki
    /// graph rather than leaving the section blank.
    internal static func stored(_ rawValue: String) -> GraphSurface {
        GraphSurface(rawValue: rawValue) ?? .wiki
    }
}
