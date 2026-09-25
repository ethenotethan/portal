import SwiftUI

/// The native inventory renderer for the `components`, `interplay.invariants`, `stores` and `externals` sections of the contract.
@MainActor
internal struct ArchitectureInventorySectionView: View {
    internal let document: ArchitectureModelDocument

    internal var body: some View {
        ArchitectureSectionPlaceholder(
            icon: ArchitectureSurfaceTab.inventory.icon,
            title: "Inventory",
            detail: "Components with their files and declarations, the invariants and their status, the data stores and the external systems."
        )
    }
}
