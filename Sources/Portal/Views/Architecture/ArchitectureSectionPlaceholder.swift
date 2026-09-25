import SwiftUI

/// What a section shows before its native renderer lands: the section named,
/// what it will show, and that the web observatory tab renders it meanwhile.
@MainActor
internal struct ArchitectureSectionPlaceholder: View {
    internal let icon: String
    internal let title: String
    internal let detail: String

    internal var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Text("Native renderer pending · the Observatory tab renders this section today")
                .font(.caption2)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
