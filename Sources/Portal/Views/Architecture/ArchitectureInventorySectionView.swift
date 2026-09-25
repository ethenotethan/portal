import SwiftUI

/// The native inventory renderer for the `components`, `interplay.invariants`,
/// `stores` and `externals` sections of the contract: components by layer on
/// the left (select one for its files and declarations), then the invariants
/// with their status, the stores by persistence mechanism, and the external
/// systems by category. One search narrows every section.
@MainActor
internal struct ArchitectureInventorySectionView: View {
    @State private var model: ArchitectureInventoryModel

    internal init(document: ArchitectureModelDocument) {
        _model = State(initialValue: ArchitectureInventoryModel(inventory: ArchitectureInventoryDocument.decode(document)))
    }

    internal var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Theme.border)
            HStack(spacing: 0) {
                componentList
                    .frame(width: 300)
                Divider().background(Theme.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        if let component = model.selectedComponent {
                            componentDetail(component)
                        }
                        invariantsSection
                        storesSection
                        externalsSection
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.background)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            TextField("Search components, files, declarations, invariants, stores, externals…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .monospaced()
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            Text(headerCounts)
                .font(.system(size: 10, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var headerCounts: String {
        "\(model.componentCount) components · \(model.totalFiles) files · \(model.totalLines.formatted()) lines · "
            + "\(model.invariantsHolding)/\(model.inventory.invariants.count) invariants hold"
    }

    // MARK: Components

    private var componentList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.layerGroups) { group in
                    layerHeader(group)
                    ForEach(group.components) { component in
                        componentRow(component)
                    }
                }
                if model.layerGroups.isEmpty {
                    Text("No component matches the search.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                        .padding(14)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func layerHeader(_ group: ArchitectureInventoryModel.LayerGroup) -> some View {
        HStack {
            Text(group.label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
            Spacer()
            Text("\(group.components.count) · \(group.fileCount) files")
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func componentRow(_ component: ArchitectureComponentRecord) -> some View {
        let selected = model.selectedComponentID == component.id
        return Button {
            model.selectedComponentID = selected ? nil : component.id
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text(component.label)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                Spacer()
                Text("\(component.fileCount)f · \(component.declarationCount)d")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(selected ? Theme.surfaceHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(component.description)
    }

    private func componentDetail(_ component: ArchitectureComponentRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(
                component.label,
                note: "\(model.inventory.layerLabel(component.layer)) · \(component.fileCount) files · "
                    + "\(component.lineCount.formatted()) lines · \(component.declarationCount) declarations"
            )
            Text(component.description)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    columnTitle("Files (\(model.selectedFiles.count))")
                    ForEach(model.selectedFiles, id: \.self) { path in
                        Text(path)
                            .font(.system(size: 10, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    columnTitle("Declarations (\(model.selectedDeclarations.count))")
                    ForEach(model.selectedDeclarations, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .monospaced()
                            .foregroundStyle(Theme.primary)
                    }
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Invariants

    private var invariantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(
                "Invariants",
                note: "\(model.invariantsHolding) of \(model.inventory.invariants.count) hold at this revision; each is declared and checked on every build"
            )
            ForEach(model.invariants) { invariant in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    statusPill(invariant.status, holds: invariant.holds)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(invariant.id)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .monospaced()
                                .foregroundStyle(Theme.primary)
                            Text(invariant.kind)
                                .font(.system(size: 9, design: .monospaced))
                                .monospaced()
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text(invariant.why)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }
            if model.invariants.isEmpty {
                emptyNote(model.inventory.invariants.isEmpty ? "The document declares no invariants." : "No invariant matches the search.")
            }
        }
    }

    // MARK: Stores

    private var storesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Data stores", note: "\(model.inventory.stores.count) store types, grouped by the persistence mechanism observed in their bodies")
            if !model.inventory.hasStoresSection {
                emptyNote("This document carries no stores section (optional in the contract).")
            }
            ForEach(model.storeGroups) { group in
                groupHeader(group.label, count: group.items.count)
                ForEach(group.items) { store in
                    storeRow(store)
                }
            }
            if model.inventory.hasStoresSection && model.storeGroups.isEmpty {
                emptyNote(model.inventory.stores.isEmpty ? "No store type was recognised." : "No store matches the search.")
            }
        }
    }

    private func storeRow(_ store: ArchitectureStoreRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                if let evidence = store.evidence {
                    Text(evidence.location)
                        .font(.system(size: 9, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                }
                if !store.mechanisms.isEmpty {
                    Text("Mechanisms: " + store.mechanisms.joined(separator: ", "))
                        .font(.system(size: 10, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.secondary)
                }
                ForEach(store.artifacts, id: \.self) { artifact in
                    Text("\(artifact.kind)  \(artifact.label)")
                        .font(.system(size: 10, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.primary)
                }
                if store.artifacts.isEmpty {
                    Text("No file, folder or defaults key named in the store body.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.leading, 6)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Text(store.label)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.primary)
                Text(store.kind)
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.tertiary)
                Spacer()
                Text("\(store.artifacts.count) artifact(s)")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.secondary)
            }
        }
        .tint(Theme.secondary)
    }

    // MARK: Externals

    private var externalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("External systems", note: "\(model.inventory.externals.count) declared boundaries, each observed by its configured signatures")
            if !model.inventory.hasExternalsSection {
                emptyNote("This document carries no externals section (optional in the contract).")
            }
            ForEach(model.externalGroups) { group in
                groupHeader(group.label, count: group.items.count)
                ForEach(group.items) { external in
                    externalRow(external)
                }
            }
            if model.inventory.hasExternalsSection && model.externalGroups.isEmpty {
                emptyNote(model.inventory.externals.isEmpty ? "No external system is declared." : "No external system matches the search.")
            }
        }
    }

    private func externalRow(_ external: ArchitectureExternalRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(external.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                if !external.protocolName.isEmpty {
                    Text(external.protocolName)
                        .font(.system(size: 9, design: .monospaced))
                        .monospaced()
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(external.hitCount) hits · \(external.fileCount) files")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(Theme.secondary)
            }
            Text(external.description)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(note)
                .font(.system(size: 10, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
        }
    }

    private func columnTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.tertiary)
    }

    private func groupHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
            Text("\(count)")
                .font(.system(size: 9, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.top, 6)
    }

    private func statusPill(_ status: String, holds: Bool) -> some View {
        let color: Color = holds ? Theme.success : Theme.warning
        return Text(status.uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .monospaced()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
    }
}
