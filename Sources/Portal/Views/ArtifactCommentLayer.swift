import SwiftUI

/// Comment controls over a live HTML artifact: a button that arms the next
/// click on the page to drop a pin, a native composer for the note, and the
/// list of what has been said. The page only reports where the reader
/// clicked; every word is typed and shown in this trusted chrome.
///
/// On a gateway without `artifact.comment` the content renders bare.
internal struct ArtifactCommentLayer<Content: View>: View {
    internal let artifactID: String
    @ViewBuilder internal let content: (HTMLArtifactCommentBridge.Host?) -> Content

    @EnvironmentObject private var capabilitiesStore: GatewayCapabilitiesStore
    @ObservedObject private var artifacts = ArtifactStore.shared
    @ObservedObject private var store = ArtifactStore.shared.comments
    @State private var isPlacing = false
    @State private var selectedID: String?
    @State private var showList = false
    @State private var draft: Draft?

    /// A pin the reader has placed but not yet written a note for.
    private struct Draft: Identifiable {
        internal let id = UUID()
        internal let anchor: ArtifactCommentAnchor
        internal var body = ""
    }

    private var comments: [ArtifactComment] { store.comments(for: artifactID) }
    private var currentRev: Int { artifacts.artifacts[artifactID]?.rev ?? 0 }

    private var host: HTMLArtifactCommentBridge.Host {
        HTMLArtifactCommentBridge.Host(
            state: HTMLArtifactCommentBridge.PageState(
                isPlacing: isPlacing,
                selectedID: selectedID,
                pins: HTMLArtifactCommentBridge.pins(for: comments, selectedID: selectedID)
            ),
            onRequest: handle
        )
    }

    internal var body: some View {
        if capabilitiesStore.capabilities.supportsArtifactComments {
            content(host)
                .overlay(alignment: .topTrailing) { controls }
                .task(id: artifactID) { await store.refresh(artifactID: artifactID) }
                .sheet(item: $draft) { composer($0) }
        } else {
            content(nil)
        }
    }

    private func handle(_ request: HTMLArtifactCommentRequest) {
        switch request {
        case .place(let anchor):
            isPlacing = false
            draft = Draft(anchor: anchor)
        case .open(let commentID):
            selectedID = commentID
            showList = true
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 6) {
            if isPlacing {
                Text("Click the page to pin a comment")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Button {
                isPlacing.toggle()
            } label: {
                Image(systemName: isPlacing ? "xmark" : "plus.bubble")
            }
            .help(isPlacing ? "Cancel" : "Pin a comment to the page")
            .accessibilityLabel(isPlacing ? "Cancel comment" : "Add comment")
            Button {
                showList.toggle()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("\(store.openCount(for: artifactID))")
                }
            }
            .help("Comments on this artifact")
            .accessibilityLabel("Comments")
            .popover(isPresented: $showList, arrowEdge: .top) { list }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isPlacing ? Theme.accent : Theme.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.surface.opacity(0.94), in: Capsule())
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .padding(8)
    }

    // MARK: - Composer

    private func composer(_ current: Draft) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New comment").font(.headline)
            if !current.anchor.text.isEmpty {
                Text(current.anchor.text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 2) }
            }
            TextEditor(text: Binding(
                get: { draft?.body ?? "" },
                set: { draft?.body = $0 }
            ))
            .font(.system(size: 13))
            .frame(minHeight: 96)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            if let failure = store.failure {
                Text(failure).font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    store.clearFailure()
                    draft = nil
                }
                Button("Comment") { save(current) }
                    .keyboardShortcut(.defaultAction)
                    .disabled((draft?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 340, idealWidth: 420)
    }

    private func save(_ current: Draft) {
        let body = draft?.body ?? ""
        Task {
            let stored = await store.add(
                artifactID: artifactID, artifactRev: currentRev, anchor: current.anchor, body: body)
            // A failed save keeps the sheet and the reader's words.
            if stored { draft = nil }
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if comments.isEmpty {
                Text("No comments yet. Use the + button, then click the page.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            row(comment, number: index + 1)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .frame(width: 340)
    }

    private func row(_ comment: ArtifactComment, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(comment.resolved ? Theme.border : Theme.warning, in: Capsule())
                Text(comment.createdAt, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                Spacer()
                Text(status(comment))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(comment.body)
                .font(.system(size: 12))
                .foregroundStyle(comment.resolved ? Theme.secondary : Theme.primary)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Button(comment.resolved ? "Reopen" : "Resolve") {
                    Task {
                        await store.setResolved(
                            artifactID: artifactID, commentID: comment.id, resolved: !comment.resolved)
                    }
                }
                Button("Delete", role: .destructive) {
                    Task { await store.delete(artifactID: artifactID, commentID: comment.id) }
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(comment.id == selectedID ? Theme.surfaceHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = comment.id == selectedID ? nil : comment.id }
    }

    /// The one fact about a comment's state worth a label.
    private func status(_ comment: ArtifactComment) -> String {
        if comment.resolved { return comment.resolvedByAgent ? "Resolved by agent" : "Resolved" }
        if comment.anchor.isWholeArtifact { return "Whole artifact" }
        return comment.rev < currentRev ? "Page changed since" : ""
    }
}
