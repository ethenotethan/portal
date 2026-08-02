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
    /// Every job in the list, used to offer the categories that already exist as
    /// move destinations. Empty is fine — the picker then offers only Ungrouped
    /// and a new category.
    internal let siblingJobs: [CronJob]
    /// Receives the raw typed name; normalization happens again in the view model
    /// so no caller can persist a trailing separator.
    internal let onRename: (String) -> Void

    /// Picking a destination, not retyping a path. Typing the full name is still
    /// reachable via `.rename`, because a leaf genuinely does need renaming
    /// sometimes — but it is no longer the price of moving a job.
    private enum Mode: Equatable {
        case idle
        case move
        case rename
    }

    @State private var mode: Mode = .idle
    /// Chosen destination while in `.move`, seeded from the job's current path so
    /// the picker opens on where it already sits. Empty means Ungrouped.
    @State private var destination: [String] = []
    /// Free-text path for the "New category…" affordance inside `.move`.
    @State private var newCategory = ""
    @State private var isAddingCategory = false
    @State private var editedName = ""
    @FocusState private var newCategoryFocused: Bool

    internal init(
        name: String,
        isCompact: Bool,
        siblingJobs: [CronJob] = [],
        onRename: @escaping (String) -> Void
    ) {
        self.name = name
        self.isCompact = isCompact
        self.siblingJobs = siblingJobs
        self.onRename = onRename
    }

    internal var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 10) {
            header
            switch mode {
            case .idle:   breadcrumb
            case .move:   movePicker
            case .rename: editor
            }
        }
        .padding(isCompact ? 8 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: isCompact ? 8 : 14))
        // A rename refreshes the list, so this view is handed a new name while
        // still mounted; leaving the editor open would show the stale text.
        .onChange(of: name) { _, _ in reset() }
    }

    private var header: some View {
        HStack {
            // The card is about the category, but the rename branch edits the
            // whole name — saying "Category" over a full-name field is what made
            // the old editor read as "retype your path to move".
            Text(mode == .rename ? "Rename" : "Category")
                .font(isCompact ? .caption.weight(.semibold) : .headline)
                .foregroundStyle(Theme.primary)
            Spacer()
            if mode == .idle {
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
            destination = CronCategory.split(name: name).path
            isAddingCategory = false
            newCategory = ""
            mode = .move
        } label: {
            Label("Move", systemImage: "folder")
                .font(isCompact ? .caption2 : .caption)
        }
        .controlSize(.small)
        .help("Move this job into a category — its name is kept")

        if isCompact {
            button.buttonStyle(.borderless)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    // MARK: - Move (pick a destination)

    /// Destinations are *chosen*, and the job's own name is never retyped. The
    /// leaf travels untouched via `CronCategory.moved(name:to:)`, so relocating a
    /// job can't accidentally rename it.
    private var movePicker: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            Text("Move “\(CronCategory.split(name: name).title)” to")
                .font(isCompact ? .caption2 : .caption)
                .foregroundStyle(Theme.tertiary)

            destinationList

            if isAddingCategory {
                // Focus follows the reveal: picking "New category…" means the
                // user is ready to type, so don't make them click the field.
                TextField("new/category/path", text: $newCategory)
                    .font(.system(isCompact ? .caption : .callout, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .focused($newCategoryFocused)
                    .onSubmit(commitMove)
                    .onAppear { newCategoryFocused = true }
            }

            Text(movePreview)
                .font(isCompact ? .caption2 : .caption)
                .foregroundStyle(Theme.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // A typed destination can carry the same footgun as a typed name: a
            // space-bearing component is probably prose, not a nested category.
            if isAddingCategory, let warning = CronCategory.separatorWarning(
                for: CronCategory.moved(name: name, to: typedDestination) ?? ""
            ) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(isCompact ? .caption2 : .caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                Button("Rename instead") {
                    editedName = name
                    mode = .rename
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Spacer()

                Button("Cancel") { reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Move", action: commitMove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canMove)
            }
        }
    }

    /// Existing categories plus Ungrouped, as a menu rather than a long inline
    /// list: the card is narrow, and the number of categories is unbounded.
    private var destinationList: some View {
        Menu {
            Button {
                isAddingCategory = false
                destination = []
            } label: {
                Label("Ungrouped", systemImage: destination.isEmpty && !isAddingCategory
                      ? "checkmark" : "tray")
            }

            let paths = CronCategory.allPaths(in: siblingJobs)
            if !paths.isEmpty {
                Divider()
                ForEach(paths, id: \.self) { path in
                    Button {
                        isAddingCategory = false
                        destination = path
                    } label: {
                        Label(
                            CronCategory.displayPath(path),
                            systemImage: destination == path && !isAddingCategory
                                ? "checkmark" : "folder"
                        )
                    }
                }
            }

            Divider()
            Button {
                isAddingCategory = true
                newCategory = ""
            } label: {
                Label("New category…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isAddingCategory ? "folder.badge.plus" : "folder")
                    .font(.caption)
                Text(isAddingCategory
                     ? "New category"
                     : CronCategory.displayPath(destination))
                    .font(isCompact ? .caption : .subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.background, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// The typed "New category…" path, split into components. Empty when the field
    /// holds nothing usable yet.
    private var typedDestination: [String] {
        guard let normalized = CronCategory.normalize(name: newCategory) else { return [] }
        return normalized.split(separator: CronCategory.separator).map(String.init)
    }

    /// The destination actually being written — the typed one while adding.
    private var resolvedDestination: [String]? {
        guard isAddingCategory else { return destination }
        guard CronCategory.normalize(name: newCategory) != nil else { return nil }
        return typedDestination
    }

    private var movedName: String? {
        guard let path = resolvedDestination else { return nil }
        return CronCategory.moved(name: name, to: path)
    }

    private var canMove: Bool {
        guard let moved = movedName else { return false }
        return moved != name
    }

    private var movePreview: String {
        guard let moved = movedName else {
            return "Type a category path like life/training"
        }
        if moved == name { return "Already here" }
        return "Becomes “\(moved)”"
    }

    private func commitMove() {
        guard let moved = movedName, moved != name else { return }
        onRename(moved)
        reset()
    }

    private func reset() {
        mode = .idle
        isAddingCategory = false
        newCategory = ""
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

            // `/` is reserved by the convention, so a name like "A/B testing digest"
            // becomes a category. Warn rather than block — it may be intended.
            if let warning = CronCategory.separatorWarning(for: editedName) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(isCompact ? .caption2 : .caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { reset() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button("Save", action: commit)
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
        reset()
    }
}
