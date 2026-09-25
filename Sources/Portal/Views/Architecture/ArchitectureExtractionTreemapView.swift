import SwiftUI

/// Coverage by file as area: every analysed file is a cell sized by its lines
/// inside its directory's frame, filled by the share of its declarations a
/// mechanical pass cited, hatched when nothing touched it. A tap selects the
/// file under the pointer.
@MainActor
internal struct ArchitectureExtractionTreemapView: View {
    internal let tree: ArchitectureExtractionLayout.DirectoryNode
    internal let selectedPath: String?
    internal let onSelect: (String) -> Void

    internal var body: some View {
        GeometryReader { geometry in
            let treemap = ArchitectureExtractionLayout.treemap(tree, size: geometry.size)
            Canvas { context, _ in
                draw(treemap, in: &context)
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let cell = treemap.cell(at: location) {
                    onSelect(cell.file.path)
                }
            }
            .accessibilityLabel("Every analysed file sized by lines and shaded by how much of it the extractor cited")
        }
        .frame(height: 440)
        .background(Theme.surface.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }

    private func draw(_ treemap: ArchitectureExtractionLayout.Treemap, in context: inout GraphicsContext) {
        for frame in treemap.frames {
            context.stroke(Path(frame.rect), with: .color(Theme.border), lineWidth: 1)
            if frame.rect.width > 60, frame.rect.height > CGFloat(ArchitectureExtractionLayout.Metrics.treemapHeader) {
                let label = Text(frame.label.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).monospaced()
                    .foregroundStyle(Theme.tertiary.opacity(frame.depth > 1 ? 0.8 : 1))
                context.draw(
                    context.resolve(label),
                    in: CGRect(x: frame.rect.minX + 4, y: frame.rect.minY + 2, width: frame.rect.width - 8, height: 12)
                )
            }
        }
        for cell in treemap.cells {
            let rect = cell.rect.insetBy(dx: 0.5, dy: 0.5)
            guard rect.width > 0, rect.height > 0 else { continue }
            let path = Path(roundedRect: rect, cornerRadius: 1)
            if cell.file.touched {
                context.fill(path, with: .color(Theme.accent.opacity(ArchitectureExtractionPalette.cellOpacity(share: cell.file.mappedShare))))
            } else {
                context.fill(path, with: .color(Theme.surface))
                hatch(rect, in: &context)
            }
            let isSelected = cell.file.path == selectedPath
            context.stroke(path, with: .color(isSelected ? Theme.primary : Theme.background), lineWidth: isSelected ? 1.5 : 1)
            if rect.width > 46, rect.height > 16 {
                let label = Text(cell.file.fileName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).monospaced()
                    .foregroundStyle(cell.file.touched ? Theme.primary : Theme.secondary)
                context.draw(context.resolve(label), in: CGRect(x: rect.minX + 4, y: rect.minY + 3, width: rect.width - 8, height: 12))
            }
        }
    }

    /// Diagonal hatching clipped to the cell: read, cited by nothing.
    private func hatch(_ rect: CGRect, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            var lines = Path()
            let step: CGFloat = 6
            var offset = -rect.height
            while offset < rect.width {
                lines.move(to: CGPoint(x: rect.minX + offset, y: rect.maxY))
                lines.addLine(to: CGPoint(x: rect.minX + offset + rect.height, y: rect.minY))
                offset += step
            }
            layer.stroke(lines, with: .color(Theme.secondary.opacity(0.45)), lineWidth: 1)
        }
    }
}
