import SwiftUI

struct WikiPathPickerSheet: View {
    @Binding var selectedPath: String?
    var onSelect: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customPath: String = ""

    var body: some View {
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
                    .buttonStyle(.bordered)

                    Button("Load Default") {
                        onSelect(nil)
                        dismiss()
                    }
                    .buttonStyle(.bordered)

                    Button("Load Custom") {
                        let path = customPath.trimmingCharacters(in: .whitespaces)
                        onSelect(path.isEmpty ? nil : path)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
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
