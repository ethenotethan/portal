import SwiftUI

/// The native Extraction map for the `extraction` section of the contract: the
/// compiler as a projection over the source tree. The provenance wiring on top
/// (file schema wired to every construction by the rule that extracted it),
/// coverage by file as a treemap beneath, then the same facts by construct, by
/// pass, and the files nothing touched.
@MainActor
internal struct ArchitectureExtractionSectionView: View {
    private typealias Layout = ArchitectureExtractionLayout

    internal let document: ArchitectureModelDocument
    /// Where "Show on system map" goes; the system map tab wires this in.
    private let onShowOnSystemMap: (String) -> Void

    @State private var openDirectories: Set<String>?
    @State private var openKinds: Set<String> = []
    @State private var query = ""
    @State private var selection: ArchitectureExtractionLayout.Selection?

    internal init(document: ArchitectureModelDocument, onShowOnSystemMap: @escaping (String) -> Void = { _ in }) {
        self.document = document
        self.onShowOnSystemMap = onShowOnSystemMap
    }

    internal var body: some View {
        if let extraction = ArchitectureExtractionDocument.decode(document: document) {
            content(extraction)
        } else {
            ArchitectureSectionPlaceholder(
                icon: ArchitectureSurfaceTab.extraction.icon,
                title: "No extraction map",
                detail: "This document carries no `extraction` section, so nothing says where its map came from."
            )
        }
    }

    private func content(_ extraction: ArchitectureExtractionDocument) -> some View {
        let tree = Layout.tree(files: extraction.files)
        let origins = Layout.originsByFile(extraction)
        let open = openDirectories ?? Layout.defaultOpenDirectories(tree)
        let rows = Layout.rows(document: extraction, tree: tree, openDirectories: open, openKinds: openKinds, query: query, origins: origins)
        let bundles = Layout.wires(document: extraction, rows: rows)
        let highlight = Layout.highlight(for: selection, document: extraction, origins: origins)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                header(extraction)
                toolbar(tree: tree, extraction: extraction)
                HStack(alignment: .top, spacing: 12) {
                    ScrollView(.horizontal) {
                        ArchitectureExtractionWiringView(
                            rows: rows,
                            bundles: bundles,
                            highlight: highlight,
                            selection: selection,
                            query: query,
                            fileCount: extraction.files.count,
                            entityCount: extraction.entities.count,
                            onToggleDirectory: { path in
                                var next = open
                                if next.contains(path) { next.remove(path) } else { next.insert(path) }
                                openDirectories = next
                            },
                            onToggleKind: { kind in
                                if openKinds.contains(kind) { openKinds.remove(kind) } else { openKinds.insert(kind) }
                            },
                            onSelect: { choice in selection = selection == choice ? nil : choice }
                        )
                    }
                    if let selection {
                        inspector(selection, extraction: extraction, origins: origins)
                            .frame(width: 340)
                    }
                }
                legend(extraction)
                group(
                    "Coverage by file",
                    note: "The same projection as area: every analysed file is a cell sized by its lines; the fill is the share of its "
                        + "declarations a mechanical pass cited; hatched cells were read and cited by nothing."
                ) {
                    ArchitectureExtractionTreemapView(
                        tree: tree,
                        selectedPath: selection?.side == .file ? selection?.key : nil,
                        onSelect: { path in selection = Layout.Selection(side: .file, key: path) }
                    )
                }
                constructTable(extraction)
                passTable(extraction)
                untouchedList(extraction, tree: tree, origins: origins)
            }
            .padding(16)
        }
        .background(Theme.background)
    }

    // MARK: Header and toolbar

    private func header(_ extraction: ArchitectureExtractionDocument) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 24) {
                Text("The system map is the output of a function over the source tree. Each wire runs from the file and line a rule fired on "
                    + "to the entity it produced; files no wire leaves were read by every pass and cited by none. Untouched is a fact "
                    + "about the extractor's grammar, not about the code.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: 620, alignment: .leading)
                Spacer()
                HStack(spacing: 22) {
                    ForEach(Layout.stats(extraction.summary)) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stat.value)
                                .font(.system(size: 18, weight: .medium, design: .monospaced))
                                .monospaced()
                                .foregroundStyle(Theme.primary)
                            Text(stat.label.uppercased())
                                .extractionMono(9, weight: .semibold)
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
            Text("\(extraction.summary.declarations) declarations · \(extraction.summary.mappedDeclarations) mapped · "
                + "\(extraction.summary.citations) mechanical citations · \(extraction.summary.semanticCitations) semantic · authority \(extraction.authority)")
                .extractionMono(9, weight: .semibold)
                .foregroundStyle(Theme.tertiary)
            if !extraction.derivation.isEmpty {
                Text(extraction.derivation)
                    .extractionMono(10)
                    .foregroundStyle(Theme.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface.opacity(0.5))
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.success).frame(width: 2) }
            }
        }
    }

    private func toolbar(tree: ArchitectureExtractionLayout.DirectoryNode, extraction: ArchitectureExtractionDocument) -> some View {
        HStack(spacing: 8) {
            TextField("Search files, entities, declarations, or rules…", text: $query)
                .textFieldStyle(.roundedBorder)
                .extractionMono(11)
            Button("Expand all") {
                openDirectories = Set(tree.allDirectories.map(\.path))
                openKinds = Set(Layout.kinds(in: extraction))
            }
            .portalButton(prominent: false, size: .small)
            Button("Collapse all") {
                openDirectories = []
                openKinds = []
            }
            .portalButton(prominent: false, size: .small)
            Button("Reset selection") {
                selection = nil
                query = ""
            }
            .portalButton(prominent: false, size: .small)
        }
    }

    private func legend(_ extraction: ArchitectureExtractionDocument) -> some View {
        HStack(spacing: 16) {
            ForEach(ArchitectureExtractionFamily.known, id: \.rawValue) { family in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ArchitectureExtractionPalette.color(for: family))
                        .frame(width: 18, height: 3)
                    Text(family.label)
                        .help(extraction.families[family.rawValue] ?? "")
                }
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.tertiary).frame(width: 18, height: 3)
                Text("mixed families · width grows with the number of extractions bundled")
            }
        }
        .extractionMono(10)
        .foregroundStyle(Theme.tertiary)
    }

    // MARK: Inspector

    private func inspector(
        _ selection: ArchitectureExtractionLayout.Selection,
        extraction: ArchitectureExtractionDocument,
        origins: [String: [ArchitectureExtractionLayout.EntityOrigin]]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button {
                    self.selection = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("Close inspector")
            }
            switch selection.side {
            case .file:
                fileInspector(selection.key, extraction: extraction, wires: origins[selection.key] ?? [])
            case .entity:
                if let entity = extraction.entityByID[selection.key] {
                    entityInspector(entity)
                } else {
                    Text("Unknown entity").foregroundStyle(Theme.secondary)
                }
            }
        }
        .padding(14)
        .background(Theme.surface.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    private func fileInspector(
        _ path: String,
        extraction: ArchitectureExtractionDocument,
        wires: [ArchitectureExtractionLayout.EntityOrigin]
    ) -> some View {
        let file = extraction.fileByPath[path]
        return VStack(alignment: .leading, spacing: 10) {
            badge(wires.isEmpty ? "UNTOUCHED" : "\(wires.count) EXTRACTION(S) LEAVE THIS FILE", color: wires.isEmpty ? Theme.tertiary : Theme.accent)
            Text(path.split(separator: "/").last.map(String.init) ?? path)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(path)
                .extractionMono(10)
                .foregroundStyle(Theme.secondary)
                .textSelection(.enabled)
            if let file {
                Text("\(file.component ?? "unassigned") · \(file.lineCount) lines · \(file.mappedDeclarations)/\(file.declarationCount) declarations mapped"
                    + (file.semanticCitations > 0 ? " · \(file.semanticCitations) semantic citation(s)" : ""))
                    .extractionMono(10)
                    .foregroundStyle(Theme.tertiary)
            }
            sectionTitle("What the extractor produced from it")
            if wires.isEmpty {
                Text("Nothing. \(file?.declarationCount ?? 0) declaration(s) were read and no rule recognised any of them: the map and every "
                    + "invariant built on it say nothing about this file.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(wires.enumerated()), id: \.offset) { _, wire in
                        Button {
                            openKinds.insert(wire.kind)
                            selection = Layout.Selection(side: .entity, key: wire.entityID)
                        } label: {
                            originRow(
                                primary: "\(wire.kind) · \(wire.label)",
                                rule: wire.origin.rule,
                                line: wire.origin.line,
                                family: wire.origin.family,
                                via: wire.origin.via
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let file, !file.declarations.isEmpty {
                sectionTitle("Declarations (\(file.declarationCount))")
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(file.declarations.enumerated()), id: \.offset) { _, declaration in
                        HStack(spacing: 6) {
                            Text(declaration.kind)
                                .extractionMono(9, weight: .semibold)
                                .foregroundStyle(Theme.tertiary)
                                .frame(width: 64, alignment: .leading)
                            Text(declaration.name)
                                .extractionMono(11)
                                .foregroundStyle(declaration.isMapped ? Theme.primary : Theme.secondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(declaration.isMapped ? "\(declaration.passes.count) pass(es) · :\(declaration.line)" : "untouched · :\(declaration.line)")
                                .extractionMono(9, weight: .semibold)
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
            }
        }
    }

    private func entityInspector(_ entity: ArchitectureExtractedEntity) -> some View {
        let component = entity.component.map { "component \($0) · " } ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            badge(Layout.kindLabel(entity.kind).uppercased(), color: Theme.accent)
            Text(entity.label)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text("\(component)\(entity.origins.count) origin(s)")
                .extractionMono(10)
                .foregroundStyle(Theme.tertiary)
            sectionTitle("Extracted from")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entity.origins.enumerated()), id: \.offset) { _, origin in
                    originRow(primary: origin.path, rule: origin.rule, line: origin.line, family: origin.family, via: origin.via)
                }
            }
            Button("Show on system map") { onShowOnSystemMap(entity.id) }
                .portalButton(prominent: false, size: .small)
        }
    }

    private func originRow(primary: String, rule: String, line: Int, family: ArchitectureExtractionFamily, via: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(primary)
                    .extractionMono(11)
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(":\(line)")
                    .extractionMono(10)
                    .foregroundStyle(Theme.secondary)
            }
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1).fill(ArchitectureExtractionPalette.color(for: family)).frame(width: 8, height: 3)
                Text(rule + (via.map { " · via \($0)" } ?? ""))
                    .extractionMono(9, weight: .semibold)
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().background(Theme.border) }
    }

    // MARK: Tables

    private func constructTable(_ extraction: ArchitectureExtractionDocument) -> some View {
        group(
            "By construct",
            note: "What exists in the tree against what the extractor placed. Reported by declaration kind, not as a file percentage: "
                + "a count names what is missing, a percentage hides it."
        ) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    tableHeader("Kind")
                    tableHeader("Declared")
                    tableHeader("Mapped")
                    tableHeader("Unmapped")
                    tableHeader("Share")
                }
                ForEach(Layout.constructRows(extraction.summary)) { row in
                    GridRow {
                        Text(row.kind).extractionMono(11).foregroundStyle(Theme.primary)
                        numberCell(row.count.total)
                        numberCell(row.count.mapped)
                        numberCell(row.count.unmapped)
                        HStack(spacing: 8) {
                            shareBar(row.count.share)
                            Text("\(Int((row.count.share * 100).rounded()))%")
                                .extractionMono(10)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
    }

    private func passTable(_ extraction: ArchitectureExtractionDocument) -> some View {
        let passes = Layout.passRows(extraction)
        let mechanical = passes.filter(\.isMechanical).count
        return group(
            "By pass",
            note: "\(mechanical) mechanical passes cited source. Each row is one rule of the extractor's grammar: what it recognises, "
                + "how many files it fired in, and how many lines it cited."
        ) {
            Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow {
                    tableHeader("Pass")
                    tableHeader("Recognises")
                    tableHeader("Files")
                    tableHeader("Citations")
                }
                ForEach(passes) { pass in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pass.id).extractionMono(11).foregroundStyle(Theme.primary)
                            Text(pass.isMechanical ? "mechanical" : "\(pass.passClass.rawValue) · written by a person, not extraction")
                                .extractionMono(9, weight: .semibold)
                                .foregroundStyle(Theme.tertiary)
                        }
                        Text(pass.description)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: 520, alignment: .leading)
                        numberCell(pass.files)
                        numberCell(pass.citations)
                    }
                    .opacity(pass.isMechanical ? 1 : 0.6)
                }
            }
        }
    }

    private func untouchedList(
        _ extraction: ArchitectureExtractionDocument,
        tree: ArchitectureExtractionLayout.DirectoryNode,
        origins: [String: [ArchitectureExtractionLayout.EntityOrigin]]
    ) -> some View {
        let groups = Layout.untouchedGroups(extraction, query: query, origins: origins)
        return group(
            "Untouched files",
            note: "\(extraction.summary.untouchedFiles) of \(extraction.summary.files) analysed files were read by every pass and cited by none. "
                + "They are assigned to a component and counted in the inventory; the map and the invariants say nothing about what is inside them."
        ) {
            if groups.isEmpty {
                Text(query.isEmpty ? "Every analysed file was cited by at least one pass." : "No untouched file matches the search.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(group.directory) · \(group.files.count)")
                                .extractionMono(9, weight: .semibold)
                                .foregroundStyle(Theme.tertiary)
                            ForEach(group.files) { file in
                                Button {
                                    var next = openDirectories ?? Layout.defaultOpenDirectories(tree)
                                    next.insert(file.directory)
                                    openDirectories = next
                                    selection = Layout.Selection(side: .file, key: file.path)
                                } label: {
                                    HStack(spacing: 8) {
                                        Text(file.fileName)
                                            .extractionMono(11)
                                            .foregroundStyle(Theme.secondary)
                                        Text("\(file.declarationCount) declaration(s) · \(file.lineCount) lines")
                                            .extractionMono(9, weight: .semibold)
                                            .foregroundStyle(Theme.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Pieces

    private func group<Content: View>(_ title: String, note: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(note)
                .extractionMono(10)
                .foregroundStyle(Theme.tertiary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .extractionMono(9, weight: .semibold)
            .foregroundStyle(Theme.tertiary)
            .padding(.top, 6)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .extractionMono(9, weight: .semibold)
            .foregroundStyle(color)
    }

    private func tableHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .extractionMono(9, weight: .semibold)
            .foregroundStyle(Theme.tertiary)
    }

    private func numberCell(_ value: Int) -> some View {
        Text(value.formatted())
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .monospaced()
            .foregroundStyle(Theme.primary)
    }

    private func shareBar(_ share: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.border)
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: geometry.size.width * CGFloat(min(1, max(0, share))))
            }
        }
        .frame(width: 120, height: 6)
    }
}
