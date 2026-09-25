import SwiftUI

internal struct WikiPathPickerSheet: View {
    @Binding internal var selectedPath: String?
    internal var onSelect: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customPath: String = ""

    internal var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Select Wiki")
                    .font(.headline)
                    .foregroundStyle(Theme.primary)

                TextField("Custom wiki path (optional)", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .portalButton()

                    Button("Load Default") {
                        onSelect(nil)
                        dismiss()
                    }
                    .portalButton()

                    Button("Load Custom") {
                        let path = customPath.trimmingCharacters(in: .whitespaces)
                        onSelect(path.isEmpty ? nil : path)
                        dismiss()
                    }
                    .portalButton(prominent: true)
                    .disabled(customPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)

                Spacer()
            }
            .padding(.top, 20)
            .frame(minWidth: 400, minHeight: 200)
            .background(Theme.background)
        }
    }
}
