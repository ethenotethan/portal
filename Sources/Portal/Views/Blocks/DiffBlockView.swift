import SwiftUI

/// Renders ```diff blocks as a real diff: per-line add/remove tinting,
/// hunk headers, file headers, and an add/remove count in the chrome —
/// instead of the plain code block diffs used to fall into.
struct DiffBlockView: View {
    let code: String
    @State private var isCopied = false

    private var lines: [DiffLine] { DiffLine.parse(code) }

    private var stats: (added: Int, removed: Int) {
        let l = lines
        return (l.filter { $0.kind == .addition }.count,
                l.filter { $0.kind == .deletion }.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border.opacity(0.5))
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        DiffLineView(line: line)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Diff")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
            let s = stats
            Text("+\(s.added)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.green)
            Text("−\(s.removed)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.red)
            Spacer()
            OpenInPanelButton {
                Artifact(kind: .diff, title: "Diff", content: code)
            }
            Button {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                #else
                UIPasteboard.general.string = code
                #endif
                isCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isCopied = false
                }
            } label: {
                Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help("Copy raw diff")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

// MARK: - Line model

struct DiffLine: Identifiable {
    enum Kind {
        case addition       // +…
        case deletion       // -…
        case hunk           // @@ -a,b +c,d @@
        case fileHeader     // diff --git / --- a/… / +++ b/… / index …
        case context        // everything else
    }

    let id: Int
    let kind: Kind
    let text: String

    /// Classify unified-diff lines. Order matters: "---"/"+++" file markers
    /// must win over the -/+ prefixes they share.
    static func parse(_ code: String) -> [DiffLine] {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, raw in
                let line = String(raw)
                let kind: Kind
                if line.hasPrefix("@@") {
                    kind = .hunk
                } else if line.hasPrefix("+++") || line.hasPrefix("---")
                            || line.hasPrefix("diff ") || line.hasPrefix("index ")
                            || line.hasPrefix("new file") || line.hasPrefix("deleted file")
                            || line.hasPrefix("rename ") || line.hasPrefix("similarity ") {
                    kind = .fileHeader
                } else if line.hasPrefix("+") {
                    kind = .addition
                } else if line.hasPrefix("-") {
                    kind = .deletion
                } else {
                    kind = .context
                }
                return DiffLine(id: index, kind: kind, text: line)
            }
    }
}

// MARK: - Line view

private struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: return .green
        case .deletion: return .red
        case .hunk: return Theme.accent
        case .fileHeader: return Theme.secondary
        case .context: return Theme.primary.opacity(0.85)
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: return .green.opacity(0.10)
        case .deletion: return .red.opacity(0.10)
        case .hunk: return Theme.accent.opacity(0.06)
        case .fileHeader, .context: return .clear
        }
    }
}
