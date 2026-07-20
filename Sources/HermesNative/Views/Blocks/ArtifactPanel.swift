import SwiftUI
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ArtifactPanel")

// MARK: - Artifact

/// A block of generated content promoted out of the transcript into the
/// side panel: code, a diff, or a whole markdown document. Identity is the
/// content hash so re-opening the same block reuses the panel instead of
/// stacking.
struct Artifact: Identifiable, Equatable {
    enum Kind: Equatable {
        case code(language: String)
        case diff
        case markdown
        /// A living artifact rendered by its fence kind (map/chart/graph/stats).
        /// artifactID keys the store so the panel reads live updates.
        case living(kind: String, artifactID: String)
    }

    let kind: Kind
    let title: String
    let content: String

    var id: Int {
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(content)
        return hasher.finalize()
    }

    /// Suggested filename for Save.
    var suggestedFilename: String {
        let base = title
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stem = base.isEmpty ? "artifact" : String(base.prefix(40))
        switch kind {
        case .code(let language):
            return "\(stem).\(Self.fileExtension(for: language))"
        case .diff:
            return "\(stem).patch"
        case .markdown:
            return "\(stem).md"
        case .living:
            return "\(stem).json"
        }
    }

    private static func fileExtension(for language: String) -> String {
        switch language.lowercased() {
        case "swift": return "swift"
        case "python", "py": return "py"
        case "javascript", "js": return "js"
        case "typescript", "ts": return "ts"
        case "rust", "rs": return "rs"
        case "go": return "go"
        case "ruby", "rb": return "rb"
        case "java": return "java"
        case "kotlin", "kt": return "kt"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "sh", "bash", "zsh": return "sh"
        case "sql": return "sql"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "html", "htm": return "html"
        case "css": return "css"
        case "xml": return "xml"
        case "": return "txt"
        default: return "txt"
        }
    }
}

// MARK: - Environment plumbing

/// Optional open-in-panel action. Views deep inside the markdown renderer
/// read this; when absent (PDF export, previews, iOS) no affordance shows —
/// an optional environment VALUE, not an EnvironmentObject, precisely so
/// absence is a no-op instead of a crash.
private struct OpenArtifactKey: EnvironmentKey {
    static let defaultValue: (@MainActor (Artifact) -> Void)? = nil
}

extension EnvironmentValues {
    var openArtifact: (@MainActor (Artifact) -> Void)? {
        get { self[OpenArtifactKey.self] }
        set { self[OpenArtifactKey.self] = newValue }
    }
}

/// Small header-chrome button shared by every block that can promote its
/// content to the panel.
struct OpenInPanelButton: View {
    let artifact: () -> Artifact
    @Environment(\.openArtifact) private var openArtifact

    var body: some View {
        if let openArtifact {
            Button {
                openArtifact(artifact())
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Open in side panel")
        }
    }
}

// MARK: - Panel

#if os(macOS)
/// The right-hand artifact pane: renders the promoted content full-height
/// with copy/save chrome, independent of transcript scroll position.
struct ArtifactPanelView: View {
    let artifact: Artifact
    let onClose: () -> Void
    @State private var isCopied = false
    @ObservedObject private var store = ArtifactStore.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                content
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
    }

    @ViewBuilder
    private var content: some View {
        switch artifact.kind {
        case .code(let language):
            CodeBlockView(language: language, code: artifact.content)
        case .diff:
            DiffBlockView(code: artifact.content)
        case .markdown:
            MarkdownContentView(text: artifact.content, isStreaming: false)
                .equatable()
        case .living(let kind, let artifactID):
            livingContent(kind: kind, artifactID: artifactID)
        }
    }

    /// Living artifacts render with the same block views as chat, reading
    /// LIVE from the store so agent updates appear while the panel is open.
    @ViewBuilder
    private func livingContent(kind: String, artifactID: String) -> some View {
        let content = store.artifacts[artifactID]?.content ?? artifact.content
        switch kind {
        case "map":
            MapBlockView(json: content, isStreaming: false)
        case "chart":
            NativeChartView(json: content, isStreaming: false, interactive: true)
        case "graph":
            NetworkGraphView(json: content, isStreaming: false)
        case "stats":
            StatTilesView(json: content, isStreaming: false)
        default:
            MarkdownContentView(text: content, isStreaming: false)
                .equatable()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.accent)
            Text(artifact.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .lineLimit(1)
            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(artifact.content, forType: .string)
                isCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { isCopied = false }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy contents")

            Button(action: save) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Save to file…")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.tertiary)
                    .frame(width: 24, height: 24)
                    .background(Theme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close panel")
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var iconName: String {
        switch artifact.kind {
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .diff: return "plus.forwardslash.minus"
        case .markdown: return "doc.richtext"
        case .living(let kind, _):
            switch kind {
            case "map": return "map"
            case "chart": return "chart.bar"
            case "graph": return "point.3.connected.trianglepath.dotted"
            case "stats": return "gauge.medium"
            default: return "internaldrive"
            }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.suggestedFilename
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try artifact.content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                log.error("Artifact save failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
