import SwiftUI

/// The views of a service's architecture surface: one native tab per contract
/// section (`hermes.architecture`). The web observatory is the GitHub Pages
/// export of the same document, not part of the app.
internal enum ArchitectureSurfaceTab: String, CaseIterable, Hashable {
    case systemMap
    case extraction
    case gates
    case inventory

    internal var title: String {
        switch self {
        case .systemMap: return "System map"
        case .extraction: return "Extraction map"
        case .gates: return "CI gates"
        case .inventory: return "Inventory"
        }
    }

    internal var icon: String {
        switch self {
        case .systemMap: return "point.3.connected.trianglepath.dotted"
        case .extraction: return "square.grid.3x1.below.line.grid.1x2"
        case .gates: return "checklist"
        case .inventory: return "list.bullet.rectangle"
        }
    }

    /// The contract section a tab renders.
    internal var section: ArchitectureSection {
        switch self {
        case .systemMap: return .interplay
        case .extraction: return .extraction
        case .gates: return .ci
        case .inventory: return .components
        }
    }

    /// The tabs a document can show: a tab appears only when its section is
    /// present, so a non-conforming document never shows an empty renderer.
    internal static func available(for document: ArchitectureModelDocument) -> [ArchitectureSurfaceTab] {
        allCases.filter { document.has($0.section) }
    }
}
