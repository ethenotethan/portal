import SwiftUI

/// Shared fallback for a structured artifact block whose JSON didn't parse:
/// a captioned card showing the raw source. Mirrors the inline fallback the
/// older block views (dataset/timeline) each carry, factored out so the
/// newer kinds don't retriplicate it.
internal struct ArtifactParseError: View {
    internal let kind: String
    internal let json: String

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Couldn't parse \(kind) block")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            Text(json)
                .font(.system(.caption2, design: .monospaced))
                .monospaced()
                .foregroundStyle(Theme.tertiary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
