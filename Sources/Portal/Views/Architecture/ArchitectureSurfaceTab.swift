import SwiftUI

/// The views of a service's architecture surface: one native tab per contract
/// section (`hermes.architecture`), plus the service's log sinks and its stored
/// revisions. The web observatory is the GitHub Pages export of the same
/// document, not part of the app.
internal enum ArchitectureSurfaceTab: String, CaseIterable, Hashable {
    case systemMap
    case extraction
    case gates
    case inventory
    case logs
    case revisions

    internal var title: String {
        switch self {
        case .systemMap: return "System map"
        case .extraction: return "Extraction map"
        case .gates: return "CI gates"
        case .inventory: return "Inventory"
        case .logs: return "Logs"
        case .revisions: return "Revisions"
        }
    }

    internal var icon: String {
        switch self {
        case .systemMap: return "point.3.connected.trianglepath.dotted"
        case .extraction: return "square.grid.3x1.below.line.grid.1x2"
        case .gates: return "checklist"
        case .inventory: return "list.bullet.rectangle"
        case .logs: return "text.alignleft"
        case .revisions: return "clock.arrow.circlepath"
        }
    }

    /// The contract section a tab renders; the logs and revisions tabs read the
    /// gateway (sinks, snapshots) rather than a section of the document.
    internal var section: ArchitectureSection? {
        switch self {
        case .systemMap: return .interplay
        case .extraction: return .extraction
        case .gates: return .ci
        case .inventory: return .components
        case .logs, .revisions: return nil
        }
    }

    /// The tabs a document can show: a section tab appears only when its
    /// section is present, so a non-conforming document never shows an empty
    /// renderer; Logs appears only when the service declares a sink; Revisions
    /// is always there, since every described service has at least one snapshot.
    internal static func available(for document: ArchitectureModelDocument) -> [ArchitectureSurfaceTab] {
        allCases.filter { tab in
            switch tab {
            case .logs: return !document.service.logs.isEmpty
            case .revisions: return true
            default: return tab.section.map(document.has) ?? false
            }
        }
    }
}
