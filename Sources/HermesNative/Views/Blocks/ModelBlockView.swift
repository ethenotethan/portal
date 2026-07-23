import SwiftUI

/// Renders a ```model block — the ensemble artifact: every declared view
/// stacked on ONE surface over one entity store, with a shared selection
/// bus. Click an apartment in the table → its pin highlights on the map and
/// its relations light up in the graph. Views are projections (see
/// ModelProjections) onto the existing block renderers.
struct ModelBlockView: View {
    let json: String
    let isStreaming: Bool
    /// Set by artifact hosts: enables declared per-entity actions and the
    /// relations panel. Chat transcript blocks render read-only.
    var actionableArtifactID: String?

    var body: some View {
        if let spec = ModelSpec.parse(json) {
            ModelCard(spec: spec, actionableArtifactID: actionableArtifactID)
        } else if isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't parse model block")
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
}

private struct ModelCard: View {
    let spec: ModelSpec
    var actionableArtifactID: String?

    /// The selection bus: one selected entity ref shared by every view.
    /// Stored as the "set/normalizedKey" string every projection uses as
    /// its stable id (map marker label is bare key — mapped below).
    @State private var selectedRef: ModelSpec.EntityRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ForEach(spec.views) { view in
                viewBlock(view)
            }
            if let ref = selectedRef {
                selectionPanel(ref)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(spec.title ?? spec.id ?? "Model")
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Spacer()
            Text(entityCountSummary)
                .font(.caption2)
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var entityCountSummary: String {
        spec.entitySets
            .map { "\($0.items.count) \($0.name)" }
            .joined(separator: " · ")
    }

    // MARK: Views (projections onto existing renderers)

    @ViewBuilder
    private func viewBlock(_ view: ModelSpec.View) -> some View {
        switch view.kind {
        case .map:
            if let json = ModelProjections.mapJSON(spec: spec, view: view) {
                MapBlockView(
                    json: json, isStreaming: false,
                    externalSelection: markerSelectionBinding(for: view)
                )
            }
        case .table:
            ForEach(spec.sets(for: view), id: \.name) { set in
                ModelEntityTable(
                    spec: spec, set: set, columns: view.columns,
                    actionableArtifactID: actionableArtifactID,
                    selectedRef: $selectedRef
                )
            }
        case .graph:
            if let json = ModelProjections.graphJSON(spec: spec, view: view) {
                NetworkGraphView(json: json, isStreaming: false)
            }
        case .chart:
            if let json = ModelProjections.chartJSON(spec: spec, view: view) {
                NativeChartView(json: json, isStreaming: false)
            }
        case .stats:
            if let json = ModelProjections.statsJSON(spec: spec, view: view) {
                StatTilesView(json: json, isStreaming: false)
            }
        }
    }

    /// Map selection speaks marker labels (bare key values); the bus speaks
    /// refs. Translate both ways, resolving a bare label to whichever set in
    /// this view contains it.
    private func markerSelectionBinding(for view: ModelSpec.View) -> Binding<String?> {
        Binding(
            get: { selectedRef.flatMap { spec.item(for: $0) != nil ? labelFor($0) : nil } },
            set: { newLabel in
                guard let newLabel else {
                    selectedRef = nil
                    return
                }
                for set in spec.sets(for: view) {
                    let ref = ModelSpec.EntityRef(set: set.name, key: newLabel)
                    if spec.item(for: ref) != nil {
                        selectedRef = ref
                        return
                    }
                }
            }
        )
    }

    private func labelFor(_ ref: ModelSpec.EntityRef) -> String? {
        guard let set = spec.entitySet(named: ref.set) else { return nil }
        return set.items.first {
            ($0[set.key] ?? "").trimmingCharacters(in: .whitespaces).lowercased() == ref.key
        }?[set.key]
    }

    // MARK: Selection panel (entity card + its relations)

    private func selectionPanel(_ ref: ModelSpec.EntityRef) -> some View {
        let item = spec.item(for: ref)
        let related = spec.relations(touching: ref)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(labelFor(ref) ?? ref.key)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(ref.set)
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Theme.accent.opacity(0.12), in: Capsule())
                Spacer()
                Button {
                    selectedRef = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
            if let item {
                let setKey = spec.entitySet(named: ref.set)?.key ?? "id"
                let fields = item.keys.sorted().filter { $0 != setKey && $0 != "lat" && $0 != "lon" }
                if !fields.isEmpty {
                    Text(fields.map { "\($0): \(item[$0] ?? "")" }.joined(separator: "  ·  "))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .textSelection(.enabled)
                }
            }
            ForEach(related) { relation in
                relationRow(relation, from: ref)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    /// "—walkable→ FelixMuayThai (8 min)" — tap the far end to jump the bus.
    private func relationRow(_ relation: ModelSpec.Relation, from ref: ModelSpec.EntityRef) -> some View {
        let other = relation.from == ref ? relation.to : relation.from
        let arrow = relation.from == ref ? "→" : "←"
        return Button {
            selectedRef = other
        } label: {
            HStack(spacing: 5) {
                Text("\(arrow) \(relation.type)")
                    .font(.caption2)
                    .foregroundStyle(Theme.tertiary)
                Text(labelFor(other) ?? other.key)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.accent)
                if let note = relation.note {
                    Text("(\(note))")
                        .font(.caption2)
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Entity table (one per set in a table view)

/// Sortable table over one entity set: key + columns + declared action
/// controls per row, selection wired to the model's bus.
private struct ModelEntityTable: View {
    let spec: ModelSpec
    let set: ModelSpec.EntitySet
    let columns: [String]
    var actionableArtifactID: String?
    @Binding var selectedRef: ModelSpec.EntityRef?

    @State private var sortField: String?
    @State private var sortAscending = true

    private var displayColumns: [String] {
        if !columns.isEmpty { return columns }
        var seen = Set<String>([set.key, "lat", "lon"])
        var derived = [set.key]
        for item in set.items {
            for field in item.keys.sorted() where seen.insert(field).inserted {
                derived.append(field)
            }
        }
        return derived
    }

    private var actions: [ArtifactAction] { spec.actions[set.name] ?? [] }

    private var sortedItems: [[String: String]] {
        guard let field = sortField else { return set.items }
        return set.items.sorted { a, b in
            let left = a[field] ?? ""
            let right = b[field] ?? ""
            if let ln = Double(left), let rn = Double(right) {
                return sortAscending ? ln < rn : ln > rn
            }
            return sortAscending
                ? left.localizedCaseInsensitiveCompare(right) == .orderedAscending
                : left.localizedCaseInsensitiveCompare(right) == .orderedDescending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(set.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            headerRow
            Divider().overlay(Theme.border)
            ForEach(sortedItems.indices, id: \.self) { index in
                row(sortedItems[index])
                Divider().overlay(Theme.border.opacity(0.4))
            }
        }
        .background(Theme.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            ForEach(displayColumns, id: \.self) { field in
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
                .frame(minWidth: field == set.key ? 110 : 60,
                       maxWidth: field == set.key ? .infinity : nil, alignment: .leading)
            }
            if !actions.isEmpty && actionableArtifactID != nil {
                Text("").frame(minWidth: 90)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func row(_ item: [String: String]) -> some View {
        let keyValue = item[set.key] ?? ""
        let ref = ModelSpec.EntityRef(set: set.name, key: keyValue)
        let isSelected = selectedRef == ref
        return HStack(spacing: 8) {
            ForEach(displayColumns, id: \.self) { field in
                Text(item[field] ?? "")
                    .font(.system(size: 11, weight: field == set.key ? .medium : .regular))
                    .foregroundStyle(field == set.key ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                    .frame(minWidth: field == set.key ? 110 : 60,
                           maxWidth: field == set.key ? .infinity : nil, alignment: .leading)
            }
            if !actions.isEmpty, let artifactID = actionableArtifactID {
                ArtifactActionControls(
                    actions: actions,
                    entryKey: "\(set.name)/\(keyValue)",
                    fieldValue: { item[$0] },
                    artifactID: artifactID
                )
                .frame(minWidth: 90, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accent.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRef = isSelected ? nil : ref
        }
    }
}
