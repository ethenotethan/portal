import SwiftUI

/// Shows where a cron job sits in the category tree and lets the user move it.
///
/// Rename and recategorize are deliberately the same operation: a job's category
/// IS its name path (see `CronCategory`), so editing `db-backup` into
/// `infra/db-backup` refiles it on the next list with no migration step and no
/// separate schema field. That is also why the control is labeled "Category" and
/// "Move" rather than "Name" and "Rename" — reorganizing is the reason to reach
/// for it, even though a rename is what goes over the wire.
///
/// Shared by the compact `CronJobCard` and the full `CronJobDetailView` so the
/// normalization preview and the disabled-Save rules can't drift between them.
/// Gateway-only: Standard's dashboard API has no update endpoint, so callers gate
/// this on `supportsRemoveAndEdit`.
internal struct CronCategoryEditor: View {
    /// The job's current full name (path included).
    internal let name: String
    /// Card-sized type and spacing rather than detail-page sized.
    internal let isCompact: Bool
    /// Receives the raw typed name; normalization happens again in the view model
    /// so no caller can persist a trailing separator.
    internal let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var editedName = ""

    internal init(name: String, isCompact: Bool, onRename: @escaping (String) -> Void) {
        self.name = name
        self.isCompact = isCompact
        self.onRename = onRename
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            header
            if isEditing {
                editor
            } else {
                breadcrumb
            }
        }
        .padding(isCompact ? 8 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: isCompact ? 8 : 14))
        // A rename refreshes the list, so this view is handed a new name while
        // still mounted; leaving the editor open would show the stale text.
        .onChange(of: name) { _, _ in isEditing = false }
    }

    private var header: some View {
        HStack {
            Text("Category")
                .font(isCompact ? .caption.weight(.semibold) : .headline)
                .foregroundStyle(Theme.primary)
            Spacer()
            if !isEditing {
                moveButton
            }
        }
    }

    /// The compact card sits inside a already-bordered row, so the button is
    /// borderless there and bordered on the roomier detail page — matching how
    /// the adjacent prompt editor's Edit button reads in each context.
    @ViewBuilder
    private var moveButton: some View {
        let button = Button {
            editedName = name
            isEditing = true
        } label: {
            Label("Move", systemImage: "folder")
                .font(isCompact ? .caption2 : .caption)
        }
        .controlSize(.small)
        .help("Rename the job to move it into a category")

        if isCompact {
            button.buttonStyle(.borderless)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    /// Where the job currently sits. An uncategorized job says "Ungrouped"
    /// outright instead of rendering blank — "Move" is precisely what it wants.
    private var breadcrumb: some View {
        let split = CronCategory.split(name: name)
        return HStack(spacing: isCompact ? 4 : 5) {
            if split.path.isEmpty {
                Text("Ungrouped")
                    .font(isCompact ? .caption : .subheadline)
                    .foregroundStyle(Theme.tertiary)
            } else {
                ForEach(Array(split.path.enumerated()), id: \.offset) { index, level in
                    if index > 0 {
                        separatorChevron
                    }
                    Text(level)
                        .font(isCompact ? .caption : .subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                separatorChevron
            }
            Text(split.title)
                .font(isCompact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                .foregroundStyle(Theme.primary)
            Spacer(minLength: 0)
        }
    }

    private var separatorChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: isCompact ? 7 : 8, weight: .semibold))
            .foregroundStyle(Theme.tertiary)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            TextField("life/training/morning-run", text: $editedName)
                .font(.system(isCompact ? .caption : .body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)

            // The path is a convention, not a validated field, so show where the
            // name actually lands: a trailing slash or a doubled separator
            // collapses silently, and seeing that beats guessing.
            Text(preview)
                .font(isCompact ? .caption2 : .caption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Move", action: commit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!CronCategory.isRenameable(editedName, from: name))
            }
        }
    }

    /// Human-readable destination for the pending rename.
    private var preview: String {
        guard let normalized = CronCategory.normalize(name: editedName) else {
            return "Enter a name, optionally as a path like life/training/run"
        }
        if normalized == name { return "Already here" }
        let split = CronCategory.split(name: normalized)
        guard !split.path.isEmpty else {
            return "Moves to Ungrouped as “\(split.title)”"
        }
        return "Moves to \(split.path.joined(separator: " › ")) as “\(split.title)”"
    }

    private func commit() {
        guard CronCategory.isRenameable(editedName, from: name) else { return }
        onRename(editedName)
        isEditing = false
    }
}
