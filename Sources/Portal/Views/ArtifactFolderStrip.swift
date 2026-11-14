import SwiftUI

/// The folder tabs above an artifact list: All, one chip per folder, and
/// Unfiled when anything is. Chips wrap, so every folder stays one click away
/// however narrow the sidebar is. A value view: `.equatable()` skips the body
/// unless the folders, their counts, or the selection change.
internal struct ArtifactFolderStrip: View, Equatable {
    internal let index: ArtifactFolderIndex
    internal let selection: ArtifactFolderSelection
    internal let onSelect: (ArtifactFolderSelection) -> Void

    nonisolated internal static func == (lhs: ArtifactFolderStrip, rhs: ArtifactFolderStrip) -> Bool {
        lhs.index == rhs.index && lhs.selection == rhs.selection
    }

    internal var body: some View {
        FlowLayout(spacing: 5) {
            chip(.all, title: "All", icon: "tray.2", count: index.totalCount)
            ForEach(index.folders) { folder in
                chip(.folder(folder.name), title: folder.name, icon: "folder", count: folder.count)
            }
            if index.unfiledCount > 0 {
                chip(.unfiled, title: "Unfiled", icon: "tray", count: index.unfiledCount)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("artifactFolderStrip")
    }

    private func chip(
        _ target: ArtifactFolderSelection, title: String, icon: String, count: Int
    ) -> some View {
        let isSelected = target == selection
        return Button {
            onSelect(target)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isSelected && icon == "folder" ? "folder.fill" : icon)
                    .font(.system(size: 9))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .monospaced()
                    .foregroundStyle(isSelected ? Theme.accent.opacity(0.8) : Theme.tertiary)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: 200)
            .background(
                isSelected ? Theme.accent.opacity(0.12) : Theme.surfaceHover.opacity(0.6),
                in: Capsule()
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) artifacts")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The "Move to Folder" submenu of an artifact's context menu: every existing
/// folder (the current one checked), a new folder, and out of its folder.
/// Holds the store as a plain reference and calls it directly, like the row's
/// Delete, rather than hiding the dispatch in a closure.
internal struct ArtifactFolderMenu: View {
    internal let artifactID: String
    internal let category: String
    internal let folders: [String]
    internal let store: ArtifactStore
    internal let onNewFolder: () -> Void

    internal var body: some View {
        Menu {
            ForEach(folders, id: \.self) { name in
                Button {
                    store.setCategory(id: artifactID, category: name)
                } label: {
                    if name == category {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            if !folders.isEmpty { Divider() }
            Button(action: onNewFolder) {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            if !category.isEmpty {
                Button {
                    store.setCategory(id: artifactID, category: "")
                } label: {
                    Label("Remove from Folder", systemImage: "folder.badge.minus")
                }
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }
}

/// Asks for a new folder's name and files the pending artifact under it.
/// Folders exist only while something is filed in them, so "new folder" is
/// always "move this artifact into a folder with this name".
private struct ArtifactNewFolderPrompt: ViewModifier {
    @Binding var artifactID: String?
    let store: ArtifactStore
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert("New Folder", isPresented: isPresented) {
            TextField("Folder name", text: $name)
            Button("Move") {
                let folder = ArtifactFolderIndex.normalize(name)
                if let artifactID, !folder.isEmpty {
                    store.setCategory(id: artifactID, category: folder)
                }
                name = ""
            }
            Button("Cancel", role: .cancel) { name = "" }
        } message: {
            Text("The artifact moves into the new folder.")
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { artifactID != nil },
            set: { shown in if !shown { artifactID = nil } }
        )
    }
}

extension View {
    /// Present the new-folder prompt while `artifactID` names an artifact.
    internal func artifactNewFolderPrompt(artifactID: Binding<String?>, store: ArtifactStore) -> some View {
        modifier(ArtifactNewFolderPrompt(artifactID: artifactID, store: store))
    }
}
