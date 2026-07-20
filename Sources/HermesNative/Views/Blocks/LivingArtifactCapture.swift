import SwiftUI

/// Captures fenced blocks that declare an `"id"` into the ArtifactStore as
/// living artifacts, and badges the block so the user knows it's saved.
///
/// Applied to the JSON fence kinds (map/chart/graph/stats). Capture fires
/// when the block finishes streaming; re-renders of the same content are
/// deduped by the (id, content-hash) pair so scrolling a transcript doesn't
/// re-upsert (and re-push to the gateway) on every appearance.
struct LivingArtifactCapture: ViewModifier {
    let kind: String
    let json: String
    let isStreaming: Bool

    @State private var capturedHash: Int?

    /// Extracted (id, title) when the payload declares an id.
    private var identity: (id: String, title: String?)? {
        guard json.contains("\"id\""),
              let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else { return nil }
        return (id, obj["title"] as? String)
    }

    func body(content: Content) -> some View {
        if let identity {
            content
                .overlay(alignment: .topTrailing) {
                    savedBadge
                }
                .task(id: json.hashValue) {
                    guard !isStreaming else { return }
                    let hash = json.hashValue
                    guard capturedHash != hash else { return }
                    capturedHash = hash
                    ArtifactStore.shared.upsert(
                        id: identity.id, kind: kind,
                        title: identity.title, content: json
                    )
                }
        } else {
            content
        }
    }

    private var savedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "internaldrive")
                .font(.system(size: 8))
            Text(identity?.id ?? "")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Theme.background.opacity(0.85), in: Capsule())
        .padding(6)
        .help("Living artifact — updates with this id merge into the saved model")
        .allowsHitTesting(false)
    }
}

extension View {
    func captureLivingArtifact(kind: String, json: String, isStreaming: Bool) -> some View {
        modifier(LivingArtifactCapture(kind: kind, json: json, isStreaming: isStreaming))
    }
}
