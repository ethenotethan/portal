import SwiftUI

struct SkillMarkdownEditor: View {
    let viewModel: SkillsViewModel
    let skill: SkillInfo
    @Binding var content: String
    @Binding var isEditing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isEditing {
                    TextEditor(text: $content)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Theme.background)
                } else {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                }
            }
            .navigationTitle(skill.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if isEditing {
                        Button("Save") {
                            Task {
                                let ok = await viewModel.saveSkillMarkdown(name: skill.name, content: content)
                                if ok { isEditing = false }
                            }
                        }
                    } else {
                        Button("Edit") {
                            isEditing = true
                        }
                    }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}
