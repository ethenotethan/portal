import SwiftUI

/// The native extraction map renderer for the `extraction` section of the contract.
@MainActor
internal struct ArchitectureExtractionSectionView: View {
    internal let document: ArchitectureModelDocument

    internal var body: some View {
        ArchitectureSectionPlaceholder(
            icon: ArchitectureSurfaceTab.extraction.icon,
            title: "Extraction map",
            detail: "Where the map came from: the file schema wired to every construction by the rule that extracted it, coverage by file, and what nothing touched."
        )
    }
}
