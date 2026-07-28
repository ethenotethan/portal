import SwiftUI

/// The table half of a composite map artifact: every marker as a sortable
/// row — label, group, arbitrary data fields (status, reached_out, rent…)
/// and the declared action controls inline. Rendered BELOW the map in
/// artifact hosts so the spatial view and the status table are one surface
/// over one content body: click a row → the pin highlights; tap a pin → the
/// row highlights (selection binding is shared with the map).
struct MapEntryTableView: View {
    let spec: MapSpec
    let artifactID: String
    @Binding var selectedMarkerID: String?

    @State private var sortField: String?
    @State private var sortAscending = true

    /// Columns: label + group + the union of data fields riding on markers
    /// (action fields like status/reached_out land here automatically).
    private var dataFields: [String] {
        var seen = Set<String>()
        var fields: [String] = []
        for marker in spec.markers {
            for field in marker.extra.keys.sorted() where seen.insert(field).inserted {
                fields.append(field)
            }
        }
        // Fields the declared actions write always get a column, even before
        // the first mark is made (otherwise the control writes into a field
        // the table doesn't show).
        for action in spec.actions where !action.field.isEmpty && seen.insert(action.field).inserted {
            fields.append(action.field)
        }
        return fields
    }

    private var sortedMarkers: [MapSpec.Marker] {
        guard let field = sortField else { return spec.markers }
        return spec.markers.sorted { a, b in
            let left = value(of: a, field: field)
            let right = value(of: b, field: field)
            // Numeric-aware compare, string fallback.
            if let ln = Double(left), let rn = Double(right) {
                return sortAscending ? ln < rn : ln > rn
            }
            return sortAscending
                ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    private func value(of marker: MapSpec.Marker, field: String) -> String {
        switch field {
        case "label": return marker.label
        case "group": return marker.group ?? ""
        default: return marker.extra[field] ?? ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
            Divider().overlay(Theme.border)
            ForEach(sortedMarkers) { marker in
                row(marker)
                Divider().overlay(Theme.border.opacity(0.4))
            }
        }
        .background(Theme.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var allColumns: [String] { ["label", "group"] + dataFields }

    private var headerRow: some View {
        HStack(spacing: 8) {
            ForEach(allColumns, id: \.self) { field in
                Button {
                    if sortField == field {
                        sortAscending.toggle()
                    } else {
                        sortField = field
                        sortAscending = true
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(field.replacingOccurrences(of: "_", with: " "))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(sortField == field ? Theme.accent : Theme.secondary)
                        if sortField == field {
                            Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .frame(minWidth: columnMinWidth(field), maxWidth: field == "label" ? .infinity : nil, alignment: .leading)
            }
            if !spec.actions.isEmpty {
                Text("")
                    .frame(minWidth: 90)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func columnMinWidth(_ field: String) -> CGFloat {
        field == "label" ? 120 : 64
    }

    private func row(_ marker: MapSpec.Marker) -> some View {
        let isSelected = selectedMarkerID == marker.id
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                ForEach(allColumns, id: \.self) { field in
                    Text(value(of: marker, field: field))
                        .font(.system(size: 11, weight: field == "label" ? .medium : .regular))
                        .foregroundStyle(field == "label" ? Theme.primary : Theme.secondary)
                        .lineLimit(1)
                        .frame(minWidth: columnMinWidth(field), maxWidth: field == "label" ? .infinity : nil, alignment: .leading)
                }
                if !spec.actions.isEmpty {
                    ArtifactActionControls(
                        actions: spec.actions,
                        entryKey: marker.label,
                        fieldValue: { marker.extra[$0] },
                        artifactID: artifactID
                    )
                    .frame(minWidth: 90, alignment: .trailing)
                }
            }
            // The note doesn't fit a column; selected row reveals it.
            if isSelected, let note = marker.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accent.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedMarkerID = isSelected ? nil : marker.id
        }
    }
}
