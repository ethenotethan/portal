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
                .monospaced()
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
                .portalButton(prominent: true, size: .small)
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

/// Mutable, testable form state for the per-wiki glossary sheet.
@MainActor
internal final class WikiGlossaryEditorModel: ObservableObject {
    internal enum Status: Equatable {
        case idle
        case loading
        case saving
        case conflict
        case failed(String)
    }

    internal struct Term: Identifiable, Equatable {
        internal let id: UUID
        internal var canonical: String
        internal var aliases: String
        internal var description: String

        internal init(
            id: UUID = UUID(),
            canonical: String = "",
            aliases: String = "",
            description: String = ""
        ) {
            self.id = id
            self.canonical = canonical
            self.aliases = aliases
            self.description = description
        }
    }

    internal let wiki: String?
    @Published internal var version = 1
    @Published internal var mode: WikiGlossary.Mode = .canonicalize
    @Published internal var revision = ""
    @Published internal var terms: [Term] = []
    @Published internal var status: Status = .idle

    internal init(wiki: String?) {
        self.wiki = wiki
    }

    internal var validationMessage: String? {
        var problems: [String] = []
        let names = terms.map { $0.canonical.trimmingCharacters(in: .whitespacesAndNewlines) }
        if names.contains(where: \.isEmpty) {
            problems.append("Every term needs a canonical name.")
        }

        var spellings = Set<String>()
        var hasDuplicate = false
        for term in terms {
            let aliases = Self.parseAliases(term.aliases)
            for spelling in [term.canonical.trimmingCharacters(in: .whitespacesAndNewlines)] + aliases
            where !spelling.isEmpty {
                if !spellings.insert(spelling.lowercased()).inserted {
                    hasDuplicate = true
                }
            }
        }
        if hasDuplicate {
            problems.append("Canonical names and aliases must be unique.")
        }
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    internal var isValid: Bool { validationMessage == nil }
    internal var isBusy: Bool { status == .loading || status == .saving }
    internal var canSave: Bool { status == .idle && isValid }

    internal var errorMessage: String? {
        if case .failed(let message) = status { return message }
        return nil
    }

    internal func load(using source: any WikiGlossarySource) async {
        status = .loading
        do {
            seed(from: try await source.wikiGlossary(wiki: wiki))
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    internal func save(using source: any WikiGlossarySource) async -> Bool {
        guard isValid else { return false }
        status = .saving
        do {
            let saved = try await source.wikiGlossaryUpdate(
                wiki: wiki,
                version: version,
                mode: mode,
                properNouns: normalizedTerms,
                ifMatch: revision
            )
            seed(from: saved)
            status = .idle
            return true
        } catch is WikiGlossaryConflict {
            status = .conflict
            return false
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }

    internal func addTerm() {
        terms.append(Term())
    }

    internal func removeTerm(id: UUID) {
        terms.removeAll { $0.id == id }
    }

    private var normalizedTerms: [WikiGlossary.ProperNoun] {
        terms.map { term in
            let description = term.description.trimmingCharacters(in: .whitespacesAndNewlines)
            return WikiGlossary.ProperNoun(
                canonical: term.canonical.trimmingCharacters(in: .whitespacesAndNewlines),
                aliases: Self.parseAliases(term.aliases),
                description: description.isEmpty ? nil : description
            )
        }
    }

    private func seed(from glossary: WikiGlossary) {
        version = glossary.version
        mode = glossary.mode
        revision = glossary.revision
        terms = glossary.properNouns.map { term in
            Term(
                canonical: term.canonical,
                aliases: term.aliases.joined(separator: "\n"),
                description: term.description ?? ""
            )
        }
    }

    private static func parseAliases(_ value: String) -> [String] {
        value.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Sheet for editing the glossary attached to the wiki that was selected when
/// the sheet opened. Harness remains the only YAML parser and policy authority.
internal struct WikiGlossaryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: WikiGlossaryEditorModel
    private let source: any WikiGlossarySource

    internal init(wiki: String?, source: any WikiGlossarySource) {
        _model = StateObject(wrappedValue: WikiGlossaryEditorModel(wiki: wiki))
        self.source = source
    }

    internal var body: some View {
        NavigationStack {
            Group {
                if model.status == .loading {
                    ProgressView("Loading glossary…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    editor
                }
            }
            .navigationTitle("\(model.wiki ?? "Default") glossary")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.status == .saving ? "Saving…" : "Save") {
                        Task {
                            if await model.save(using: source) { dismiss() }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 520)
        .task { await model.load(using: source) }
    }

    private var editor: some View {
        Form {
            Section("Policy") {
                Picker("Mode", selection: $model.mode) {
                    ForEach(WikiGlossary.Mode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(policyExplanation)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }

            Section("Proper nouns") {
                if model.terms.isEmpty {
                    Text("No terms yet. Add names whose spelling this wiki should control.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }

                ForEach($model.terms) { $term in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Canonical spelling", text: $term.canonical)
                            Button(role: .destructive) {
                                model.removeTerm(id: term.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove term")
                        }
                        Text("Aliases (one per line)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        TextEditor(text: $term.aliases)
                            .frame(minHeight: 56)
                        TextField("Description (optional)", text: $term.description)
                    }
                    .padding(.vertical, 4)
                }

                Button {
                    model.addTerm()
                } label: {
                    Label("Add term", systemImage: "plus")
                }
            }

            if let validation = model.validationMessage {
                Section {
                    Label(validation, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warning)
                }
            }

            if model.status == .conflict {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("The glossary changed elsewhere.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.callout.weight(.semibold))
                        Text("Reload before saving so newer vocabulary is not overwritten.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        Button("Reload") { Task { await model.load(using: source) } }
                    }
                }
            } else if let error = model.errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Glossary unavailable", systemImage: "exclamationmark.triangle")
                            .font(.callout.weight(.semibold))
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.secondary)
                        Button("Retry") { Task { await model.load(using: source) } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var policyExplanation: String {
        switch model.mode {
        case .canonicalize:
            return "Configured aliases are normalized to each canonical spelling. Unknown names continue unchanged."
        case .strict:
            return "Unlisted generated proper nouns are rejected. Add a term before generated wiki operations may use it."
        }
    }
}
