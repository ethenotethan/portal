import SwiftUI

/// A theme-aware segmented control — the app's replacement for
/// `.pickerStyle(.segmented)`, which renders as a stock macOS/iOS control that
/// ignores the palette. This mirrors the app idiom (selected = `Theme.accent`
/// on a filled capsule, unselected = `Theme.secondary`) and tracks whatever
/// palette `ThemeManager` currently has set.
///
/// Generic over any `Hashable` case set, so it drops in wherever a two-or-more
/// way switch is needed (e.g. an artifact's Rendered / History tabs).
internal struct ThemedSegmentedControl<Value: Hashable>: View {
    @Binding internal var selection: Value
    internal let options: [Value]
    /// Human label for a case.
    internal let label: (Value) -> String
    /// Optional SF Symbol shown before the label.
    internal var icon: (Value) -> String? = { _ in nil }

    @Namespace private var pillNamespace

    internal var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                segment(option)
            }
        }
        .padding(3)
        .background(Theme.surface, in: Capsule())
        .overlay(Capsule().stroke(Theme.border.opacity(0.6), lineWidth: 0.5))
    }

    @ViewBuilder
    private func segment(_ option: Value) -> some View {
        let isSelected = option == selection
        Button {
            guard option != selection else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                selection = option
            }
        } label: {
            HStack(spacing: 5) {
                if let symbol = icon(option) {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(label(option))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Theme.accent.opacity(0.14))
                        .matchedGeometryEffect(id: "selectedPill", in: pillNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
