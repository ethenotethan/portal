import SwiftUI
import MapKit

/// JSON contract for ```map fenced blocks — point maps rendered with MapKit:
/// ```json
/// {
///   "id": "bkk-apartments",              // optional: living artifact id
///   "title": "BKK Apartment Hunt",
///   "markers": [
///     {"lat": 13.7248, "lon": 100.5847, "label": "Ekkamai loft",
///      "group": "shortlist", "note": "฿38k/mo, 2BR, near BTS"}
///   ]
/// }
/// ```
/// Groups color pins from the shared categorical palette; select a pin (on
/// the map or in the entry list) for its note. `id` makes it a living
/// artifact: re-emitted blocks with the same id merge markers by label.
struct MapSpec: Decodable {
    struct Marker: Decodable, Identifiable {
        let lat: Double
        let lon: Double
        let label: String
        let group: String?
        let note: String?

        var id: String { label }
        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    let id: String?
    let title: String?
    let markers: [Marker]

    /// Distinct groups in first-appearance order.
    var groups: [String] {
        var seen = Set<String>()
        return markers.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    static func parse(_ json: String) -> MapSpec? {
        guard let data = json.data(using: .utf8),
              let spec = try? JSONDecoder().decode(MapSpec.self, from: data),
              !spec.markers.isEmpty else { return nil }
        return spec
    }
}

/// Renders a ```map block. Region auto-fits the markers with padding.
struct MapBlockView: View {
    let json: String
    let isStreaming: Bool
    /// Fullscreen host mode: the map fills the container and the entry list
    /// becomes a sidebar column instead of a stacked footer.
    var isExpanded: Bool = false

    /// Shared categorical palette (chart/graph parity).
    private static let palette: [Color] = [
        "#3987e5", "#008300", "#d55181", "#c98500",
        "#199e70", "#d95926", "#9085e9", "#e66767",
    ].compactMap { Color(hex: $0) }

    var body: some View {
        if let spec = MapSpec.parse(json) {
            MapCard(spec: spec, isExpanded: isExpanded)
        } else if isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't parse map block")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondary)
                Text(json)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    static func color(forGroupIndex index: Int) -> Color {
        palette[index % palette.count]
    }
}

// MARK: - Card

private struct MapCard: View {
    let spec: MapSpec
    let isExpanded: Bool
    @State private var selectedMarkerID: String?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showFullscreen = false

    private var groupColors: [String: Color] {
        Dictionary(uniqueKeysWithValues: spec.groups.enumerated().map { index, group in
            (group, MapBlockView.color(forGroupIndex: index))
        })
    }

    var body: some View {
        if isExpanded {
            expandedLayout
        } else {
            inlineLayout
                #if os(macOS)
                .sheet(isPresented: $showFullscreen) {
                    fullscreenSheet
                }
                #else
                .fullScreenCover(isPresented: $showFullscreen) {
                    fullscreenSheet
                }
                #endif
        }
    }

    // MARK: Inline (chat transcript)

    private var inlineLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let title = spec.title {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                }
                Spacer()
                Button {
                    showFullscreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .help("Open fullscreen")
            }

            mapView
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if !spec.groups.isEmpty {
                legend
            }

            entryList(maxVisible: 4)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    // MARK: Expanded (fullscreen / side panel host)

    private var expandedLayout: some View {
        HStack(spacing: 0) {
            mapView
            Divider().overlay(Theme.border)
            VStack(alignment: .leading, spacing: 8) {
                if !spec.groups.isEmpty {
                    legend
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(spec.markers) { marker in
                            entryRow(marker)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }
            .frame(width: 300)
            .background(Theme.surface)
        }
    }

    private var fullscreenSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "map")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(spec.title ?? "Map")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.primary)
                Spacer()
                Button {
                    showFullscreen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                        .frame(width: 26, height: 26)
                        .background(Theme.surfaceHover, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.background)
            Divider().overlay(Theme.border)
            MapCard(spec: spec, isExpanded: true)
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        #endif
        .background(Theme.background)
    }

    // MARK: Map

    private var mapView: some View {
        Map(position: $cameraPosition, selection: $selectedMarkerID) {
            ForEach(spec.markers) { marker in
                Marker(
                    marker.label,
                    systemImage: iconForGroup(marker.group),
                    coordinate: marker.coordinate
                )
                .tint(color(for: marker))
                .tag(marker.id)
            }
        }
        .onChange(of: selectedMarkerID) { _, newID in
            // Selecting from the list recenters; selecting on the map doesn't
            // fight the camera (only move when the pin is likely off-screen
            // is hard to know — recentering on selection is predictable).
            if let id = newID, let marker = spec.markers.first(where: { $0.id == id }) {
                withAnimation {
                    cameraPosition = .region(MKCoordinateRegion(
                        center: marker.coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                    ))
                }
            }
        }
    }

    private func color(for marker: MapSpec.Marker) -> Color {
        marker.group.flatMap { groupColors[$0] } ?? Theme.accent
    }

    /// Stable per-group SF symbol so pins are tellable-apart beyond color.
    private func iconForGroup(_ group: String?) -> String {
        guard let group, let index = spec.groups.firstIndex(of: group) else { return "mappin" }
        let symbols = ["star.fill", "eye.fill", "xmark", "questionmark", "flag.fill", "heart.fill", "bookmark.fill", "bolt.fill"]
        return symbols[index % symbols.count]
    }

    // MARK: Entries

    /// Marker entries as proper rows: swatch + label + group chip, note
    /// below, selected row highlighted and scrolled-to on pin tap.
    @ViewBuilder
    private func entryList(maxVisible: Int) -> some View {
        let visible = selectedFirst(spec.markers)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(visible.prefix(maxVisible)) { marker in
                entryRow(marker)
            }
            if spec.markers.count > maxVisible {
                Button {
                    showFullscreen = true
                } label: {
                    Text("+ \(spec.markers.count - maxVisible) more — open fullscreen")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .padding(.leading, 4)
            }
        }
    }

    /// Selected marker floats to the top of the inline list so tapping a pin
    /// always reveals its entry even when the list is truncated.
    private func selectedFirst(_ markers: [MapSpec.Marker]) -> [MapSpec.Marker] {
        guard let id = selectedMarkerID,
              let index = markers.firstIndex(where: { $0.id == id }), index > 0 else {
            return markers
        }
        var reordered = markers
        let selected = reordered.remove(at: index)
        reordered.insert(selected, at: 0)
        return reordered
    }

    private func entryRow(_ marker: MapSpec.Marker) -> some View {
        let isSelected = selectedMarkerID == marker.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: iconForGroup(marker.group))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(color(for: marker))
                    .frame(width: 14)
                Text(marker.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
                if let group = marker.group {
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(color(for: marker))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(color(for: marker).opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
            }
            if let note = marker.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Theme.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMarkerID = isSelected ? nil : marker.id
        }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(spec.groups, id: \.self) { group in
                HStack(spacing: 5) {
                    Image(systemName: iconForGroup(group))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(groupColors[group] ?? Theme.accent)
                    Text(group)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.surfaceHover.opacity(0.6), in: Capsule())
            }
        }
    }
}
