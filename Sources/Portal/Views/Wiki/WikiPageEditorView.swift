import SwiftUI

/// In-place wiki page editor, swapped into the docked reader in place of the
/// reader body. Edits the markdown body plus the three frontmatter fields
/// users actually change (title, type, tags) — every other frontmatter key
/// round-trips untouched.
///
/// Save goes through `wiki.update` with the page's `updated` as an If-Match
/// precondition (the wiki is agent-maintained, so pages change under the
/// editor). A 409 surfaces a conflict banner: reload the server's latest
/// (discarding local edits) or force-save over it.
internal struct WikiPageEditorView: View {
    @ObservedObject internal var viewModel: WikiGraphViewModel
    @EnvironmentObject internal var gatewayClientWrapper: GatewayClientWrapper

    internal let path: String
    /// Exit edit mode (after a successful save, or via Cancel).
    internal let onClose: () -> Void

    /// The page as last read from the server — replaced on conflict-reload so
    /// the next save's If-Match follows the fresh `updated`.
    @State private var original: WikiPageContent
    @State private var title: String
    @State private var type: String
    @State private var tags: String
    @State private var bodyText: String

    @State private var isSaving = false
    @State private var saveError: String?
    @State private var conflict: WikiUpdateConflict?

    /// Known page types (the same set WikiGraphViewModel colors by), offered
    /// as a menu; a custom existing type is appended so nothing is lost.
    private static let knownTypes = [
        "entity", "concept", "comparison", "query", "raw",
        "meta", "glossary", "project", "goal",
    ]

    internal init(viewModel: WikiGraphViewModel, path: String, original: WikiPageContent, onClose: @escaping () -> Void) {
        self.viewModel = viewModel
        self.path = path
        self.onClose = onClose
        _original = State(initialValue: original)
        _title = State(initialValue: original.frontmatter["title"] ?? "")
        _type = State(initialValue: original.frontmatter["type"] ?? "concept")
        _tags = State(initialValue: original.frontmatter["tags"] ?? "")
        _bodyText = State(initialValue: original.body)
    }

    /// Frontmatter to send: the original block with the three edited fields
    /// overlaid (empty values drop the key). Static for tests.
    internal static func assembledFrontmatter(
        from original: [String: String], title: String, type: String, tags: String
    ) -> [String: String] {
        var fm = original
        func set(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { fm.removeValue(forKey: key) } else { fm[key] = trimmed }
        }
        set("title", title)
        set("type", type)
        set("tags", tags)
        return fm
    }

    private var currentFrontmatter: [String: String] {
        Self.assembledFrontmatter(from: original.frontmatter, title: title, type: type, tags: tags)
    }

    private var isDirty: Bool {
        bodyText != original.body || currentFrontmatter != original.frontmatter
    }

    private var typeOptions: [String] {
        Self.knownTypes.contains(type) ? Self.knownTypes : Self.knownTypes + [type]
    }

    internal var body: some View {
        VStack(spacing: 0) {
            if conflict != nil { conflictBanner }

            // Frontmatter fields
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Title")
                        .frame(width: 44, alignment: .leading)
                    TextField("Page title", text: $title)
                        .textFieldStyle(.plain)
                }
                HStack(spacing: 8) {
                    Text("Type")
                        .frame(width: 44, alignment: .leading)
                    Menu {
                        ForEach(typeOptions, id: \.self) { option in
                            Button {
                                type = option
                            } label: {
                                if option == type {
                                    Label(option, systemImage: "checkmark")
                                } else {
                                    Text(option)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(viewModel.color(for: type))
                                .frame(width: 8, height: 8)
                            Text(type)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 8))
                        }
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Theme.surfaceHover, in: Capsule())
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    Text("Tags")
                        .padding(.leading, 8)
                    TextField("comma, separated", text: $tags)
                        .textFieldStyle(.plain)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Theme.border)

            // Markdown body
            TextEditor(text: $bodyText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.border)

            // Action bar
            HStack(spacing: 10) {
                if let saveError {
                    Text(saveError)
                        .font(.caption2)
                        .foregroundStyle(Theme.warning)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .disabled(isSaving)
                Button {
                    Task { await save(force: false) }
                } label: {
                    HStack(spacing: 5) {
                        if isSaving { ProgressView().scaleEffect(0.6).frame(width: 10, height: 10) }
                        Text(isSaving ? "Saving…" : "Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isSaving || !isDirty || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    // MARK: - Conflict

    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                Text("This page changed on the server while you were editing.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.primary)
            }
            Text("Reload the latest (discards your edits), keep editing, or save over the server's version.")
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 10) {
                Button("Reload latest") { Task { await reloadLatest() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                Button("Save anyway") { Task { await save(force: true) } }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.warning)
                Button("Keep editing") { conflict = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.08))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }
    }

    // MARK: - Save / reload

    private func save(force: Bool) async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            _ = try await viewModel.savePage(
                client: gatewayClientWrapper.client,
                path: path,
                body: bodyText,
                frontmatter: currentFrontmatter,
                ifMatch: original.frontmatter["updated"],
                force: force
            )
            onClose()
        } catch let error as WikiUpdateConflict {
            conflict = error
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Discard local edits and reseed the editor from the server's latest
    /// (carried in the 409's `data.latest` when present, else re-fetched).
    private func reloadLatest() async {
        var latest = conflict?.latest
        if latest == nil {
            latest = await viewModel.loadPage(client: gatewayClientWrapper.client, path: path)
        }
        guard let latest else {
            conflict = nil
            saveError = "Couldn't load the latest version"
            return
        }
        original = latest
        title = latest.frontmatter["title"] ?? ""
        type = latest.frontmatter["type"] ?? "concept"
        tags = latest.frontmatter["tags"] ?? ""
        bodyText = latest.body
        conflict = nil
    }
}
