import SwiftUI

/// The views of a service's architecture surface. Each native tab renders one
/// contract section (`hermes.architecture`); the web tab hosts the observatory
/// renderer over the same document while the native renderers are completed.
internal enum ArchitectureSurfaceTab: String, CaseIterable, Hashable {
    case systemMap
    case extraction
    case gates
    case inventory
    case web

    internal var title: String {
        switch self {
        case .systemMap: return "System map"
        case .extraction: return "Extraction map"
        case .gates: return "CI gates"
        case .inventory: return "Inventory"
        case .web: return "Observatory"
        }
    }

    internal var icon: String {
        switch self {
        case .systemMap: return "point.3.connected.trianglepath.dotted"
        case .extraction: return "square.grid.3x1.below.line.grid.1x2"
        case .gates: return "checklist"
        case .inventory: return "list.bullet.rectangle"
        case .web: return "globe"
        }
    }

    /// The contract section a tab renders; the web tab renders the whole document.
    internal var section: ArchitectureSection? {
        switch self {
        case .systemMap: return .interplay
        case .extraction: return .extraction
        case .gates: return .ci
        case .inventory: return .components
        case .web: return nil
        }
    }

    /// The tabs a document can show: a tab appears only when its section is
    /// present, so a non-conforming document never shows an empty renderer.
    internal static func available(for document: ArchitectureModelDocument) -> [ArchitectureSurfaceTab] {
        allCases.filter { tab in
            guard let section = tab.section else { return true }
            return document.has(section)
        }
    }
}
