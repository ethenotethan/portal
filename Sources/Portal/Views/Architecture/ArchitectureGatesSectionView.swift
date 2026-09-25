import SwiftUI

/// The native CI gates renderer for the `ci` section of the contract.
@MainActor
internal struct ArchitectureGatesSectionView: View {
    internal let document: ArchitectureModelDocument

    internal var body: some View {
        ArchitectureSectionPlaceholder(
            icon: ArchitectureSurfaceTab.gates.icon,
            title: "CI gates",
            detail: "Every job as a logic gate feeding the merge, then the ratchets, architectural checks and static checks that defend the model."
        )
    }
}
