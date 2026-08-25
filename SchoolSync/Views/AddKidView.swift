import SwiftUI
import SwiftData

struct AddKidView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var colorHex = "#4A90D9"

    private let presetColors = ["#4A90D9", "#D9534F", "#5CB85C", "#F0AD4E", "#9B59B6", "#1ABC9C"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Kid's name", text: $name)
                }
                Section("Color") {
                    HStack {
                        ForEach(presetColors, id: \.self) { hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 28, height: 28)
                                    .overlay {
                                        if hex == colorHex {
                                            Circle().strokeBorder(.primary, lineWidth: 2)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add Kid")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        let kid = KidRecord(name: name.trimmingCharacters(in: .whitespaces), colorHex: colorHex)
        modelContext.insert(kid)
        try? modelContext.save()
        dismiss()
    }
}
