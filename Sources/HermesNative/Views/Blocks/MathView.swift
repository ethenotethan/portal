import SwiftUI
import SwiftMath

/// Native TeX rendering for $$…$$ / ```math blocks via SwiftMath (a Swift
/// port of iosMath — real math typesetting, no webview). Falls back to the
/// monospaced source when the TeX fails to parse, with the parse error
/// surfaced so the user (or the model, pasted back) can fix it.
struct MathView: View {
    let tex: String
    @State private var isCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "function")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Math")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tex, forType: .string)
                    #else
                    UIPasteboard.general.string = tex
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
                .help("Copy TeX source")
            }

            TypesetTeX(tex: tex)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}

/// The typeset equation itself, or the monospaced source + error on failure.
private struct TypesetTeX: View {
    let tex: String

    var body: some View {
        // MTMathListBuilder is the parse step MTMathUILabel does internally;
        // running it first lets us branch to a fallback instead of showing
        // an empty label when the TeX is malformed.
        let parseError = Self.parseError(for: tex)
        if let parseError {
            VStack(alignment: .leading, spacing: 6) {
                Text(tex)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.primary)
                    .textSelection(.enabled)
                Text(parseError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } else {
            MathLabel(tex: tex)
        }
    }

    static func parseError(for tex: String) -> String? {
        var error: NSError?
        _ = MTMathListBuilder.build(fromString: tex, error: &error)
        return error.map { "TeX parse: \($0.localizedDescription)" }
    }
}

#if os(macOS)
private struct MathLabel: NSViewRepresentable {
    let tex: String

    func makeNSView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        configure(label)
        return label
    }

    func updateNSView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        label.latex = tex
        label.fontSize = 16
        label.textColor = mtColor(Theme.primary)
        label.labelMode = .display
        label.textAlignment = .left
    }

    /// Height is intrinsic to the typeset formula, independent of proposed
    /// width (long equations clip rather than reflow — TeX display math has
    /// no line-breaking). Fixed-by-content sizing avoids the representable
    /// measure/height feedback SwiftUI layout loops are made of.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        guard intrinsic.height > 0 else { return nil }
        let width = min(intrinsic.width, proposal.width ?? intrinsic.width)
        return CGSize(width: width, height: intrinsic.height)
    }
}
#else
private struct MathLabel: UIViewRepresentable {
    let tex: String

    func makeUIView(context: Context) -> MTMathUILabel {
        let label = MTMathUILabel()
        configure(label)
        return label
    }

    func updateUIView(_ label: MTMathUILabel, context: Context) {
        configure(label)
    }

    private func configure(_ label: MTMathUILabel) {
        label.latex = tex
        label.fontSize = 16
        label.textColor = mtColor(Theme.primary)
        label.labelMode = .display
        label.textAlignment = .left
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        let intrinsic = uiView.intrinsicContentSize
        guard intrinsic.height > 0 else { return nil }
        let width = min(intrinsic.width, proposal.width ?? intrinsic.width)
        return CGSize(width: width, height: intrinsic.height)
    }
}
#endif

// MTColor is SwiftMath's typealias for NSColor/UIColor. Convert via the
// platform color type directly — an `MTColor.init(_: Color)` convenience
// extension is a trap: inside it, `NSColor(color)` resolves back to the
// extension itself (MTColor IS NSColor) and recurses forever.
@MainActor
func mtColor(_ color: Color) -> MTColor {
    #if os(macOS)
    NSColor(color)
    #else
    UIColor(color)
    #endif
}
