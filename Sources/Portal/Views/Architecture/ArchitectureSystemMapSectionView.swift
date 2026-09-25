import SwiftUI

/// The native system map renderer for the `interplay` section of the contract.
@MainActor
internal struct ArchitectureSystemMapSectionView: View {
    internal let document: ArchitectureModelDocument

    internal var body: some View {
        ArchitectureSectionPlaceholder(
            icon: ArchitectureSurfaceTab.systemMap.icon,
            title: "System map",
            detail: "The system map: the application boundary with its pages, the transport core, client extensions, endpoints, "
                + "on-device engines, the event bus and the external systems, with flows and invariants."
        )
    }
}
