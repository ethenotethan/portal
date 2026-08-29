import SwiftUI

/// Native renderer for authored technical layouts. Unlike a graph renderer, a
/// blueprint preserves the coordinates and dimensions supplied by the author.
internal struct BlueprintBlockView: View {
    internal let json: String
    internal let isStreaming: Bool

    internal var body: some View {
        if let spec = BlueprintSpec.parse(json) {
            BlueprintCard(spec: spec)
        } else if isStreaming {
            EmptyView()
        } else {
            BlueprintParseError(source: json)
        }
    }
}

internal enum BlueprintCanvasSizing {
    internal static func height(width: CGFloat, canvasWidth: Double, canvasHeight: Double) -> CGFloat {
        guard width.isFinite, width > 0, canvasWidth.isFinite, canvasWidth > 0,
              canvasHeight.isFinite, canvasHeight > 0 else { return 240 }
        return width * CGFloat(canvasHeight / canvasWidth)
    }
}

private struct BlueprintCard: View {
    internal let spec: BlueprintSpec
    @State private var selectedElementID: String?

    private var selectedElement: BlueprintSpec.Element? {
        spec.elements.first { $0.id == selectedElementID }
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = spec.title {
                HStack(spacing: 7) {
                    Image(systemName: "ruler")
                    Text(title)
                        .font(.headline)
                }
                .foregroundStyle(Theme.primary)
            }

            GeometryReader { geometry in
                blueprintCanvas(size: geometry.size)
            }
            .aspectRatio(spec.canvasWidth / spec.canvasHeight, contentMode: .fit)
            .frame(minHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let selectedElement, let note = selectedElement.note, !note.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Color(red: 0.34, green: 0.82, blue: 1))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedElement.label)
                            .font(.caption.weight(.semibold))
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                }
                .padding(9)
                .background(Theme.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        }
    }

    private func blueprintCanvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            BlueprintDrawing(spec: spec, size: size)
            ForEach(orderedElements) { element in
                BlueprintElementView(element: element, isSelected: selectedElementID == element.id)
                    .frame(
                        width: element.width.blueprintScale(from: spec.canvasWidth, to: size.width),
                        height: element.height.blueprintScale(from: spec.canvasHeight, to: size.height)
                    )
                    .position(
                        x: (element.x + element.width / 2).blueprintScale(from: spec.canvasWidth, to: size.width),
                        y: (element.y + element.height / 2).blueprintScale(from: spec.canvasHeight, to: size.height)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedElementID = selectedElementID == element.id ? nil : element.id
                    }
                    .help(element.note ?? element.label)
                    .accessibilityLabel(element.label)
                    .accessibilityValue(element.note ?? element.kind.rawValue)
            }
        }
        .background(BlueprintPalette.background)
        .contentShape(Rectangle())
        .onTapGesture { selectedElementID = nil }
    }

    private var orderedElements: [BlueprintSpec.Element] {
        spec.elements.sorted { left, right in
            if left.kind == .boundary, right.kind != .boundary { return true }
            if left.kind != .boundary, right.kind == .boundary { return false }
            return false
        }
    }
}

private struct BlueprintDrawing: View {
    internal let spec: BlueprintSpec
    internal let size: CGSize

    internal var body: some View {
        Canvas { context, canvasSize in
            if spec.showsGrid {
                drawGrid(context: &context, size: canvasSize)
            }
            drawConnections(context: &context, size: canvasSize)
        }
        .allowsHitTesting(false)
    }

    private func drawGrid(context: inout GraphicsContext, size: CGSize) {
        let xStep = max(8, 10.0.blueprintScale(from: spec.canvasWidth, to: size.width))
        let yStep = max(8, 10.0.blueprintScale(from: spec.canvasHeight, to: size.height))
        var minor = Path()
        var x: CGFloat = 0
        while x <= size.width {
            minor.move(to: CGPoint(x: x, y: 0))
            minor.addLine(to: CGPoint(x: x, y: size.height))
            x += xStep
        }
        var y: CGFloat = 0
        while y <= size.height {
            minor.move(to: CGPoint(x: 0, y: y))
            minor.addLine(to: CGPoint(x: size.width, y: y))
            y += yStep
        }
        context.stroke(minor, with: .color(BlueprintPalette.grid), lineWidth: 0.5)
    }

    private func drawConnections(context: inout GraphicsContext, size: CGSize) {
        let byID = Dictionary(uniqueKeysWithValues: spec.elements.map { ($0.id, $0) })
        for connection in spec.connections {
            guard let source = byID[connection.from], let target = byID[connection.to] else { continue }
            let start = center(of: source, size: size)
            let end = center(of: target, size: size)
            let midpointX = (start.x + end.x) / 2
            var path = Path()
            path.move(to: start)
            path.addLine(to: CGPoint(x: midpointX, y: start.y))
            path.addLine(to: CGPoint(x: midpointX, y: end.y))
            path.addLine(to: end)

            let stroke = StrokeStyle(
                lineWidth: connection.style == .physical ? 2 : 1.25,
                lineCap: .round,
                lineJoin: .round,
                dash: connection.style == .data || connection.style == .dependency ? [5, 4] : []
            )
            context.stroke(path, with: .color(BlueprintPalette.connection(connection.style)), style: stroke)

            if connection.hasArrow {
                drawArrow(context: &context, previous: CGPoint(x: midpointX, y: end.y), end: end,
                          color: BlueprintPalette.connection(connection.style))
            }
            if let label = connection.label, !label.isEmpty {
                context.draw(
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(BlueprintPalette.text),
                    at: CGPoint(x: midpointX + 4, y: (start.y + end.y) / 2 - 7),
                    anchor: .leading
                )
            }
        }
    }

    private func center(of element: BlueprintSpec.Element, size: CGSize) -> CGPoint {
        CGPoint(
            x: (element.x + element.width / 2).blueprintScale(from: spec.canvasWidth, to: size.width),
            y: (element.y + element.height / 2).blueprintScale(from: spec.canvasHeight, to: size.height)
        )
    }

    private func drawArrow(context: inout GraphicsContext, previous: CGPoint, end: CGPoint, color: Color) {
        let dx = end.x - previous.x
        let dy = end.y - previous.y
        let distance = max(0.01, hypot(dx, dy))
        let unitX = dx / distance
        let unitY = dy / distance
        let back = CGPoint(x: end.x - unitX * 8, y: end.y - unitY * 8)
        let perpendicular = CGPoint(x: -unitY * 4, y: unitX * 4)
        var arrow = Path()
        arrow.move(to: end)
        arrow.addLine(to: CGPoint(x: back.x + perpendicular.x, y: back.y + perpendicular.y))
        arrow.addLine(to: CGPoint(x: back.x - perpendicular.x, y: back.y - perpendicular.y))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }
}

private struct BlueprintElementView: View {
    internal let element: BlueprintSpec.Element
    internal let isSelected: Bool

    internal var body: some View {
        Group {
            if element.kind == .boundary {
                boundary
            } else if element.kind == .actor {
                actor
            } else {
                component
            }
        }
        .accessibilityElement(children: .ignore)
    }

    private var boundary: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(BlueprintPalette.fill.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            BlueprintPalette.stroke.opacity(isSelected ? 1 : 0.7),
                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [7, 4])
                        )
                }
            Text(element.label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(BlueprintPalette.text)
                .padding(6)
        }
    }

    private var actor: some View {
        VStack(spacing: 3) {
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .frame(maxHeight: 26)
            Text(element.label)
                .lineLimit(2)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(BlueprintPalette.text)
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BlueprintPalette.fill.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .overlay { selectionBorder }
    }

    private var component: some View {
        VStack(spacing: 3) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .medium))
            Text(element.label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.65)
        }
        .foregroundStyle(BlueprintPalette.text)
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BlueprintPalette.fill.opacity(element.kind == .note ? 0.18 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: element.kind == .storage ? 14 : 5))
        .overlay { selectionBorder }
    }

    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: element.kind == .storage ? 14 : 5)
            .stroke(BlueprintPalette.stroke, lineWidth: isSelected ? 2.5 : 1.2)
            .shadow(color: isSelected ? BlueprintPalette.stroke.opacity(0.7) : .clear, radius: 3)
    }

    private var symbolName: String {
        switch element.kind {
        case .service: return "gearshape.2"
        case .storage: return "cylinder.split.1x2"
        case .note: return "note.text"
        case .generic: return "square.dashed"
        case .boundary: return "square.dashed.inset.filled"
        case .actor: return "person.crop.circle"
        }
    }
}

private enum BlueprintPalette {
    internal static let background = Color(red: 0.025, green: 0.16, blue: 0.31)
    internal static let grid = Color(red: 0.27, green: 0.68, blue: 0.91).opacity(0.2)
    internal static let stroke = Color(red: 0.36, green: 0.84, blue: 1)
    internal static let fill = Color(red: 0.23, green: 0.69, blue: 0.94)
    internal static let text = Color(red: 0.88, green: 0.97, blue: 1)

    internal static func connection(_ style: BlueprintSpec.ConnectionStyle) -> Color {
        switch style {
        case .flow: return stroke
        case .data: return Color(red: 0.47, green: 0.95, blue: 0.78)
        case .dependency: return Color(red: 0.98, green: 0.78, blue: 0.35)
        case .physical: return text
        }
    }
}

private struct BlueprintParseError: View {
    internal let source: String

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't parse blueprint block")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            Text(source)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension Double {
    func blueprintScale(from logicalExtent: Double, to renderedExtent: CGFloat) -> CGFloat {
        guard logicalExtent.isFinite, logicalExtent > 0 else { return 0 }
        return CGFloat(self / logicalExtent) * renderedExtent
    }
}
