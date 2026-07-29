import SwiftUI

/// Cross-platform export render primitives shared by the macOS session-PDF
/// pipeline (`SessionPDFExporter`) and the per-artifact exporter
/// (`ArtifactExporter`, compiled on both platforms). These are pure SwiftUI —
/// no AppKit/UIKit — so they live outside any platform guard. The one
/// genuinely macOS-only export view (`ExportImageRow`, which needs `NSImage`)
/// stays behind `#if os(macOS)` in `SessionPDFExporter`.

/// Table rendered for export: a bordered `Grid` with a tinted header row and
/// zebra striping. Rows are normalized to the header count so ragged data
/// still lays out in a rectangle.
internal struct ExportTableView: View {
    internal let headers: [String]
    internal let rows: [[String]]

    internal var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    cell(text: header, isHeader: true)
                }
            }
            .background(Theme.accent.opacity(0.08))

            ForEach(Array(normalizedRows.enumerated()), id: \.offset) { rowIndex, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                        cell(text: value, isHeader: false)
                    }
                }
                .background(rowIndex.isMultiple(of: 2) ? Theme.background : Theme.surface.opacity(0.3))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Theme.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func cell(text: String, isHeader: Bool) -> some View {
        MarkdownText(
            text: text,
            baseColor: isHeader ? Theme.accent : nil,
            baseFont: isHeader ? .system(size: 11, weight: .bold, design: .monospaced) : .system(size: 12)
        )
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, isHeader ? 8 : 7)
    }

    private var normalizedRows: [[String]] {
        rows.map { row in
            let missing = max(0, headers.count - row.count)
            return Array((row + Array(repeating: "", count: missing)).prefix(headers.count))
        }
    }
}

/// Code block without the horizontal ScrollView or copy button — long lines
/// wrap so nothing is clipped on the page.
internal struct ExportCodeText: View {
    internal let language: String
    internal let code: String

    internal var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
            }
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border, lineWidth: 0.5)
        )
    }
}
