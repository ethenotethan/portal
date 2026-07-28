import SwiftUI

/// JSON contract for `dataset` artifacts — row-keyed records (contributor
/// tables, client lists, spend entries):
/// ```json
/// {
///   "id": "darkbloom-contributors", "key": "login",
///   "columns": ["login", "name", "commits"],
///   "actions": [{"field": "status", "type": "choice", "options": ["going", "not going"]},
///               {"field": "reached_out", "type": "toggle"}, {"type": "delete"}],
///   "rows": [{"login": "greg", "name": "Greg", "commits": 44}]
/// }
/// ```
/// `key` names the row-identity field (server merges rows by it). `columns`
/// fixes display order; absent, columns derive from the union of row keys
/// (key field first). Values may be strings, numbers, or bools. `actions`
/// declares per-row user verbs (rendered only in artifact hosts). Rows
/// carrying `_deleted: true` are tombstones — merged, never shown.
struct DatasetSpec {
    let key: String
    let columns: [String]
    let rows: [[String: String]]
    let actions: [ArtifactAction]

    static func parse(_ json: String) -> DatasetSpec? {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawRows = obj["rows"] as? [[String: Any]], !rawRows.isEmpty else { return nil }

        let key = (obj["key"] as? String) ?? "id"
        let rows: [[String: String]] = rawRows
            .filter { ($0["_deleted"] as? Bool) != true }
            .map { row in
                row.mapValues { value in
                    if let s = value as? String { return s }
                    if let n = value as? NSNumber { return "\(n)" }
                    return "\(value)"
                }
            }
        guard !rows.isEmpty else { return nil }

        var columns = (obj["columns"] as? [String]) ?? []
        if columns.isEmpty {
            var seen = Set<String>()
            var derived: [String] = []
            for row in rows {
                for field in row.keys.sorted() where seen.insert(field).inserted && field != "_deleted" {
                    derived.append(field)
                }
            }
            // Key field leads.
            if let idx = derived.firstIndex(of: key) {
                derived.remove(at: idx)
                derived.insert(key, at: 0)
            }
            columns = derived
        }
        return DatasetSpec(key: key, columns: columns, rows: rows, actions: ArtifactAction.parse(obj["actions"]))
    }
}

/// Renders a dataset through the existing sortable TableView (click-to-sort
/// headers, numeric-aware, CSV copy — all inherited). When the dataset is a
/// living artifact with declared actions, pass `actionableArtifactID` (the
/// Artifacts pane does) to append per-row action controls.
struct DatasetBlockView: View {
    let json: String
    let isStreaming: Bool
    /// Set by artifact hosts (Artifacts pane / sheets): enables the declared
    /// per-row actions, routed through ArtifactStore. Chat transcripts leave
    /// this nil — a transcript block is a snapshot, not the live model.
    var actionableArtifactID: String?

    var body: some View {
        if let spec = DatasetSpec.parse(json) {
            VStack(alignment: .leading, spacing: 0) {
                TableView(
                    headers: spec.columns,
                    rows: spec.rows.map { row in
                        spec.columns.map { row[$0] ?? "" }
                    }
                )
                if let artifactID = actionableArtifactID, !spec.actions.isEmpty {
                    DatasetActionRows(spec: spec, artifactID: artifactID)
                        .padding(.top, 8)
                }
            }
        } else if isStreaming {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Couldn't parse dataset block")
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

/// One triage row per dataset row: key + declared action controls. Lives
/// below the table (the table stays a clean, sortable data surface; actions
/// are a work surface).
private struct DatasetActionRows: View {
    let spec: DatasetSpec
    let artifactID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(spec.rows, id: \.self) { row in
                let entryKey = row[spec.key] ?? ""
                if !entryKey.isEmpty {
                    HStack(spacing: 8) {
                        Text(entryKey)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                            .frame(minWidth: 60, alignment: .leading)
                        Spacer(minLength: 4)
                        ArtifactActionControls(
                            actions: spec.actions,
                            entryKey: entryKey,
                            fieldValue: { row[$0] },
                            artifactID: artifactID
                        )
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                }
            }
        }
        .padding(6)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The declared actions of one entry, as controls: choice → menu, toggle →
/// checkbox, delete → trash button (with a confirm). Shared by dataset rows
/// and map entry rows.
struct ArtifactActionControls: View {
    let actions: [ArtifactAction]
    let entryKey: String
    /// Current value of a field on this entry (for menu checkmark / toggle state).
    let fieldValue: (String) -> String?
    let artifactID: String

    @ObservedObject private var store = ArtifactStore.shared
    @EnvironmentObject private var capabilitiesStore: HermesCapabilitiesStore
    @State private var confirmingDelete = false

    /// Intent buttons are hidden when the gateway doesn't report the
    /// artifact.action capability — the button would always error.
    private var supportsIntents: Bool { capabilitiesStore.capabilities.supportsArtifactActions }

    internal var body: some View {
        HStack(spacing: 10) {
            ForEach(actions) { action in
                // Never render intent buttons against an unsupported gateway.
                if action.kind == .intent && !supportsIntents { EmptyView() }
                else { control(for: action) }
            }
        }
    }

    @ViewBuilder
    private func control(for action: ArtifactAction) -> some View {
        switch action.kind {
        case .choice:
            Menu {
                ForEach(action.options, id: \.self) { option in
                    Button {
                        ArtifactStore.shared.applyAction(
                            artifactID: artifactID, action: action, entryKey: entryKey, value: option
                        )
                    } label: {
                        if fieldValue(action.field) == option {
                            Label(option, systemImage: "checkmark")
                        } else {
                            Text(option)
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(fieldValue(action.field) ?? action.field)
                        .font(.caption2)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7))
                }
                .foregroundStyle(fieldValue(action.field) == nil ? Theme.tertiary : Theme.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.surfaceHover.opacity(0.7), in: Capsule())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        case .toggle:
            Button {
                ArtifactStore.shared.applyAction(
                    artifactID: artifactID, action: action, entryKey: entryKey
                )
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: ArtifactAction.isTruthy(fieldValue(action.field))
                          ? "checkmark.square.fill" : "square")
                        .font(.system(size: 11))
                        .foregroundStyle(ArtifactAction.isTruthy(fieldValue(action.field))
                                         ? Theme.accent : Theme.tertiary)
                    Text(action.field.replacingOccurrences(of: "_", with: " "))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .buttonStyle(.plain)
        case .delete:
            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help("Remove entry")
            .confirmationDialog(
                "Remove \"\(entryKey)\"?", isPresented: $confirmingDelete, titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    ArtifactStore.shared.applyAction(
                        artifactID: artifactID, action: action, entryKey: entryKey
                    )
                }
            } message: {
                Text("The entry is tombstoned — agents re-emitting it won't bring it back.")
            }
        case .intent:
            IntentButton(
                action: action,
                entryKey: entryKey,
                artifactID: artifactID
            )
        }
    }
}

// MARK: - Intent button (backend action invocation)

/// Per-entry (or artifact-level) button for a backend intent.
/// Manages its own invocation state by reading from ArtifactStore and
/// dispatching invoke/confirm calls. Used by ArtifactActionControls (row
/// actions) and ArtifactTopLevelActionBar (HTML chrome / artifact-scoped).
internal struct IntentButton: View {
    internal let action: ArtifactAction
    internal let entryKey: String
    internal let artifactID: String

    @ObservedObject private var store = ArtifactStore.shared
    @State private var showConfirmation = false
    @State private var pendingChallenge = ""
    @State private var pendingPrompt = ""

    private var slotKey: String {
        store.intentSlotKey(artifactID: artifactID, bindingID: action.bindingID, entryKey: entryKey)
    }

    private var invocationState: ArtifactStore.IntentInvocationState? {
        store.intentStates[slotKey]
    }

    private var isPending: Bool {
        invocationState == .pending
    }

    internal var body: some View {
        Group {
            switch invocationState {
            case .none, .conflict:
                invokeButton
                    .overlay(alignment: .topTrailing) {
                        if case .conflict = invocationState {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.warning)
                                .offset(x: 4, y: -4)
                        }
                    }
            case .pending:
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 28, height: 16)
            case .succeeded(let message, let sessionID):
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.success)
                    if let message {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(sessionID == nil ? Theme.secondary : Theme.accent)
                            .lineLimit(1)
                    }
                    if sessionID != nil {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .onTapGesture {
                    // A contained run → jump into it; otherwise the tap just
                    // dismisses the badge as before.
                    if let sessionID {
                        ArtifactIntentSessionLink.open(sessionID: sessionID)
                    } else {
                        store.clearIntentState(
                            artifactID: artifactID, bindingID: action.bindingID, entryKey: entryKey
                        )
                    }
                }
            case .failed(let reason):
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.warning)
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .onTapGesture {
                    store.clearIntentState(
                        artifactID: artifactID, bindingID: action.bindingID, entryKey: entryKey
                    )
                }
            case .unsupported:
                EmptyView()
            case .needsConfirmation:
                invokeButton // should not happen here — handled in task below
            }
        }
        .task(id: invocationState == .needsConfirmation(challenge: pendingChallenge, prompt: pendingPrompt)) {
            // Surface the confirmation dialog when the state transitions to
            // needsConfirmation — driven by state change, not a button tap,
            // so the confirmation prompt comes from trusted gateway data.
            if case .needsConfirmation(let challenge, let prompt) = invocationState {
                pendingChallenge = challenge
                pendingPrompt = prompt
                showConfirmation = true
            }
        }
        .confirmationDialog(
            action.label,
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(action.presentationRole == .destructive ? "Confirm" : action.label,
                   role: action.presentationRole == .destructive ? .destructive : nil) {
                Task {
                    await store.confirmIntent(
                        artifactID: artifactID,
                        bindingID: action.bindingID,
                        entryKey: entryKey,
                        challenge: pendingChallenge
                    )
                }
            }
            Button("Cancel", role: .cancel) {
                store.clearIntentState(
                    artifactID: artifactID, bindingID: action.bindingID, entryKey: entryKey
                )
            }
        } message: {
            // Prompt text comes from trusted gateway data in the challenge
            // response, not from the artifact's own content.
            Text(pendingPrompt)
        }
    }

    private var invokeButton: some View {
        Button {
            Task {
                await store.invokeIntent(
                    artifactID: artifactID,
                    bindingID: action.bindingID,
                    entryKey: entryKey
                )
            }
        } label: {
            Text(action.label)
                .font(.caption2)
                .foregroundStyle(
                    action.presentationRole == .destructive ? Theme.warning : Theme.accent
                )
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    (action.presentationRole == .destructive
                        ? Theme.warning : Theme.accent).opacity(0.12),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .help(action.intentName.isEmpty ? action.label : action.intentName)
    }
}
