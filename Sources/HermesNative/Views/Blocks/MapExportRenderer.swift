import Foundation
import MapKit
import SwiftUI

/// Renders map blocks to static images for PDF export. MapKit's live Map is
/// an NSViewRepresentable — ImageRenderer rasterizes it as an empty box (the
/// same trap as webviews and scroll views) — so exports go through
/// MKMapSnapshotter and draw the pins onto the snapshot by hand.
enum MapExportRenderer {

    /// Snapshot a parsed map spec: auto-fitted region, pin dots colored by
    /// group (matching the live palette), labels beside the pins. Returns
    /// nil when markers are empty or the snapshotter fails (offline).
    static func renderImage(spec: MapSpec, size: CGSize = CGSize(width: 1040, height: 600)) async -> PlatformImage? {
        guard !spec.markers.isEmpty else { return nil }

        let options = MKMapSnapshotter.Options()
        options.region = fittedRegion(for: spec.markers)
        options.size = size
        options.showsBuildings = false

        let snapshot: MKMapSnapshotter.Snapshot
        do {
            snapshot = try await MKMapSnapshotter(options: options).start()
        } catch {
            return nil
        }
        return draw(spec: spec, on: snapshot, size: size)
    }

    private static func fittedRegion(for markers: [MapSpec.Marker]) -> MKCoordinateRegion {
        let lats = markers.map(\.lat)
        let lons = markers.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            return MKCoordinateRegion()
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2
        )
        // 40% padding around the marker bounds; floor keeps a lone marker
        // from zooming to rooftop level.
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.012, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.012, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    private static func draw(spec: MapSpec, on snapshot: MKMapSnapshotter.Snapshot, size: CGSize) -> PlatformImage? {
        let groups = spec.groups
        func color(for marker: MapSpec.Marker) -> PlatformColor {
            guard let group = marker.group, let index = groups.firstIndex(of: group) else {
                return PlatformColor.systemBlue
            }
            return PlatformColor(MapBlockView.color(forGroupIndex: index))
        }

        #if os(macOS)
        let image = NSImage(size: size)
        image.lockFocus()
        snapshot.image.draw(in: CGRect(origin: .zero, size: size))
        drawPins(spec: spec, snapshot: snapshot, color: color(for:))
        image.unlockFocus()
        return image
        #else
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            snapshot.image.draw(in: CGRect(origin: .zero, size: size))
            drawPins(spec: spec, snapshot: snapshot, color: color(for:))
        }
        #endif
    }

    private static func drawPins(
        spec: MapSpec,
        snapshot: MKMapSnapshotter.Snapshot,
        color: (MapSpec.Marker) -> PlatformColor
    ) {
        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: PlatformColor.black,
            .strokeColor: PlatformColor.white,
            // Negative width strokes AND fills — a white outline that keeps
            // labels readable over any map tile.
            .strokeWidth: -3.0,
        ]
        for marker in spec.markers {
            let point = snapshot.point(for: marker.coordinate)
            let dot = CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)
            let fill = color(marker)

            #if os(macOS)
            fill.setFill()
            NSBezierPath(ovalIn: dot).fill()
            PlatformColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: dot)
            ring.lineWidth = 2
            ring.stroke()
            #else
            guard let ctx = UIGraphicsGetCurrentContext() else { continue }
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(PlatformColor.white.cgColor)
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: dot)
            #endif

            (marker.label as NSString).draw(
                at: CGPoint(x: point.x + 9, y: point.y - 7),
                withAttributes: labelAttributes
            )
        }
    }
}

#if os(macOS)
private typealias PlatformFont = NSFont
#else
private typealias PlatformFont = UIFont
#endif
