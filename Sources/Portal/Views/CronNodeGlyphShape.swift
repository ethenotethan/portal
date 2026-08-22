import SwiftUI

// MARK: - CronNodeGlyphShape

/// The per-kind node silhouette, inscribed in its bounding rect. One source of
/// truth for the shape a kind draws as, shared by the `Canvas` node bodies and
/// selection rings and by the legend/detail swatches — so the key on the graph
/// shows exactly the outline it labels. Kind → glyph mapping lives on the view
/// model (`CronGraphViewModel.glyph(forKind:)`); this only renders it.
internal struct CronNodeGlyphShape: Shape {
    internal let glyph: CronGraphViewModel.NodeGlyph

    internal func path(in rect: CGRect) -> Path {
        switch glyph {
        case .circle:
            return Path(ellipseIn: rect)
        case .triangle:
            // Apex up, base along the bottom — an input pointing into the graph.
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
            return path
        case .cylinder:
            return Self.cylinderPath(in: rect)
        case .cluster:
            return Self.hexagonPath(in: rect)
        case .roundedSquare:
            // A running box — a long-lived process/container. Distinct from the
            // circle (a cron fires and exits) and the leaf resource shapes.
            return Path(roundedRect: rect, cornerRadius: rect.width * 0.28)
        }
    }

    /// A flat-topped hexagon — the collapsed cluster super-node. Reads as a
    /// container distinct from all four leaf silhouettes.
    private static func hexagonPath(in rect: CGRect) -> Path {
        let insetX = rect.width * 0.25
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + insetX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - insetX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - insetX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + insetX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }

    /// A database can: an elliptical lid, straight sides, and a front-bulging
    /// bottom. The body subpath and the full top ellipse are unioned in one
    /// `Path` (non-zero winding) so it fills as a solid store glyph.
    private static func cylinderPath(in rect: CGRect) -> Path {
        let capRy = rect.height * 0.22
        let topY = rect.minY + capRy
        let botY = rect.maxY - capRy
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: topY))
        path.addLine(to: CGPoint(x: rect.minX, y: botY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: botY),
                          control: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: topY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: topY),
                          control: CGPoint(x: rect.midX, y: topY + capRy))
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: capRy * 2))
        return path
    }
}
