import SwiftUI

/// The provenance wiring: the file schema on the left, the map's entities on
/// the right, one bundle of wires per (visible file row, visible entity row),
/// coloured by rule family. Directories and entity kinds open and close on
/// click; files and entities select. Everything drawn here comes from
/// `ArchitectureExtractionLayout`; this view only places it.
@MainActor
internal struct ArchitectureExtractionWiringView: View {
    private typealias Layout = ArchitectureExtractionLayout

    internal let rows: ArchitectureExtractionLayout.Rows
    internal let bundles: [ArchitectureExtractionLayout.WireBundle]
    internal let highlight: ArchitectureExtractionLayout.Highlight?
    internal let selection: ArchitectureExtractionLayout.Selection?
    internal let query: String
    internal let fileCount: Int
    internal let entityCount: Int
    internal let onToggleDirectory: (String) -> Void
    internal let onToggleKind: (String) -> Void
    internal let onSelect: (ArchitectureExtractionLayout.Selection) -> Void

    private var rowHeight: CGFloat { CGFloat(Layout.Metrics.rowHeight) }
    private var leftWidth: CGFloat { CGFloat(Layout.Metrics.leftColumnWidth) }
    private var rightWidth: CGFloat { CGFloat(Layout.Metrics.rightColumnWidth) }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                columnTitle("FILE SCHEMA · \(fileCount) FILES")
                    .frame(width: leftWidth, alignment: .leading)
                Spacer(minLength: CGFloat(Layout.Metrics.minimumWireSpan))
                columnTitle("ENTITIES ON THE MAP · \(entityCount)")
                    .frame(width: rightWidth, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.left) { row in leftRow(row) }
                }
                .frame(width: leftWidth, alignment: .topLeading)
                Spacer(minLength: CGFloat(Layout.Metrics.minimumWireSpan))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows.right) { row in rightRow(row) }
                }
                .frame(width: rightWidth, alignment: .topLeading)
            }
            .frame(minHeight: CGFloat(rows.count) * rowHeight, alignment: .top)
            .background(wireCanvas)
        }
        .padding(12)
        .background(Theme.surface.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .extractionMono(9, weight: .semibold)
            .foregroundStyle(Theme.tertiary)
    }

    // MARK: Rows

    private func leftRow(_ row: ArchitectureExtractionLayout.LeftRow) -> some View {
        let isSelected = selection?.side == .file && selection?.key == row.key
        let isLinked = Layout.isLinked(row, highlight: highlight)
        let dimmed = Layout.isDimmed(matches: row.matches, query: query, isSelected: isSelected, isLinked: isLinked, highlight: highlight)
        let count: String
        switch row.kind {
        case .directory:
            count = row.isOpen ? "" : "\(row.wiredFiles)/\(row.filePaths.count) files feed the map"
        case .file:
            count = row.originCount > 0 ? "\(row.originCount) ↗" : "\(row.declarationCount) decl · untouched"
        }
        return HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(row.depth) * CGFloat(Layout.Metrics.indent))
            if row.kind == .directory {
                Text(row.isOpen ? "▾" : "▸")
                    .extractionMono(10)
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }
            Text(row.label)
                .extractionMono(11)
                .fontWeight(row.kind == .directory || isSelected ? .semibold : .regular)
                .foregroundStyle(labelColor(isDirectoryLike: row.kind == .directory, isSelected: isSelected, isLinked: isLinked, untouched: row.isUntouchedFile))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(count)
                .extractionMono(10)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(isSelected ? Theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .opacity(dimmed ? 0.25 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            switch row.kind {
            case .directory: onToggleDirectory(row.key)
            case .file: onSelect(Layout.Selection(side: .file, key: row.key))
            }
        }
        .help(row.key)
        .accessibilityAddTraits(.isButton)
    }

    private func rightRow(_ row: ArchitectureExtractionLayout.RightRow) -> some View {
        let isSelected = selection?.side == .entity && selection?.key == row.key
        let isLinked = Layout.isLinked(row, highlight: highlight)
        let dimmed = Layout.isDimmed(matches: row.matches, query: query, isSelected: isSelected, isLinked: isLinked, highlight: highlight)
        let isKind = row.kind == .entityKind
        let count = isKind ? (row.isOpen ? "" : "\(row.entityIDs.count)") : "\(row.originCount) ↙"
        return HStack(spacing: 4) {
            if isKind {
                Text(row.isOpen ? "▾" : "▸")
                    .extractionMono(10)
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10 + CGFloat(Layout.Metrics.indent))
            }
            Text(row.label)
                .extractionMono(11)
                .fontWeight(isKind || isSelected ? .semibold : .regular)
                .foregroundStyle(labelColor(isDirectoryLike: isKind, isSelected: isSelected, isLinked: isLinked, untouched: false))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(count)
                .extractionMono(10)
                .foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 6)
        .frame(height: rowHeight)
        .background(isSelected ? Theme.surfaceHover : Color.clear, in: RoundedRectangle(cornerRadius: 3))
        .opacity(dimmed ? 0.25 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            switch row.kind {
            case .entityKind: onToggleKind(row.key)
            case .entity: onSelect(Layout.Selection(side: .entity, key: row.key))
            }
        }
        .help(row.key)
        .accessibilityAddTraits(.isButton)
    }

    private func labelColor(isDirectoryLike: Bool, isSelected: Bool, isLinked: Bool, untouched: Bool) -> Color {
        if isSelected || isLinked || isDirectoryLike { return Theme.primary }
        return untouched ? Theme.tertiary : Theme.secondary
    }

    // MARK: Wires

    private var wireCanvas: some View {
        Canvas { context, size in
            let x1 = leftWidth + 6
            let x2 = size.width - rightWidth - 8
            guard x2 > x1 else { return }
            let mid = (x1 + x2) / 2
            let hasHighlight = highlight != nil
            let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
            for bundle in bundles {
                guard bundle.sourceRow < rows.left.count, bundle.targetRow < rows.right.count else { continue }
                let y1 = CGFloat(bundle.sourceRow) * rowHeight + rowHeight / 2
                let y2 = CGFloat(bundle.targetRow) * rowHeight + rowHeight / 2
                var path = Path()
                path.move(to: CGPoint(x: x1, y: y1))
                path.addCurve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: mid, y: y1), control2: CGPoint(x: mid, y: y2))
                let onSelection = Layout.isSelected(bundle, highlight: highlight)
                let matchesQuery = !searching || (rows.left[bundle.sourceRow].matches && rows.right[bundle.targetRow].matches)
                let dimmed = !matchesQuery || (hasHighlight && !onSelection)
                let opacity = dimmed ? 0.08 : (onSelection ? 1.0 : 0.55)
                context.stroke(
                    path,
                    with: .color(ArchitectureExtractionPalette.color(for: bundle).opacity(opacity)),
                    style: StrokeStyle(lineWidth: CGFloat(bundle.width), lineCap: .round)
                )
            }
        }
    }
}
