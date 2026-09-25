import SwiftUI

/// A gateway async-delegation batch notice. Bare markers stay lightweight;
/// completed envelopes become a bordered result card whose returned content is
/// rendered as markdown instead of appearing as an unstructured raw dump.
internal struct DelegationBatchNoticeView: View {
    internal let notice: DelegationBatchNotice

    internal var body: some View {
        if let details = notice.details {
            resultCard(details: details)
        } else {
            marker
        }
    }

    private var marker: some View {
        HStack(spacing: 10) {
            rule
            title
            .foregroundStyle(Theme.tertiary)
            .fixedSize()
            rule
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    private func resultCard(details: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                title
                    .foregroundStyle(Theme.success)
                Spacer(minLength: 8)
                if let batchID = notice.batchID {
                    Text(batchID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.tertiary)
                }
            }

            Divider()
            MarkdownContentView(text: details)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.border, lineWidth: 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
    }

    private var title: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 11))
            Text(notice.label.capitalized)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
