import SwiftUI
import SwiftData

/// Where a kid's ordinary day gets written down.
///
/// This screen is the reason Morning Mode can be trusted. Without a baseline,
/// every morning is an open question the app has to answer from scratch and
/// will sometimes get wrong. With one, the question narrows to "did anything
/// change today", and a miss degrades to the normal day rather than to a wrong
/// answer stated confidently.
struct KidDefaultsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let kid: KidRecord

    @Query private var allDefaults: [KidDayDefaults]

    @State private var breakfast = ""
    @State private var lunch = ""
    @State private var clothing = ""
    @State private var standingReminder = ""
    @State private var hasLoaded = false

    private var existing: KidDayDefaults? {
        allDefaults.first { $0.kidID == kid.id }
    }

    var body: some View {
        Form {
            Section {
                TextField("Breakfast", text: $breakfast, axis: .vertical)
            } header: {
                Text("Breakfast")
            } footer: {
                Text("What happens on a normal day — \"Eats breakfast at school\" or \"Breakfast at home\". Only a change to this shows up in Morning Mode.")
            }

            Section {
                TextField("Lunch", text: $lunch, axis: .vertical)
            } header: {
                Text("Lunch")
            } footer: {
                Text("\"Hot lunch at school\" or \"Packs a lunch\". A pizza day or an ordered hot lunch will override it for that date.")
            }

            Section {
                TextField("Clothing", text: $clothing, axis: .vertical)
            } header: {
                Text("Clothing")
            } footer: {
                Text("\"Uniform\" or \"Regular clothes\". A jeans day, a spirit week theme, or a gym day is the exception that replaces it.")
            }

            Section {
                TextField("Every day", text: $standingReminder, axis: .vertical)
            } header: {
                Text("Standing reminder")
            } footer: {
                Text("Optional. Something true every day — \"Water bottle\". Day-specific reminders appear above it, they don't replace it.")
            }
        }
        .navigationTitle(kid.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                    dismiss()
                }
            }
        }
        .onAppear {
            // Guarded because .onAppear fires again when returning from a
            // pushed view, and reloading there would silently discard edits
            // the user hasn't saved yet.
            guard !hasLoaded else { return }
            hasLoaded = true

            if let existing {
                breakfast = existing.breakfast
                lunch = existing.lunch
                clothing = existing.clothing
                standingReminder = existing.standingReminder ?? ""
            }
        }
    }

    private func save() {
        let record = existing ?? {
            let created = KidDayDefaults(kidID: kid.id)
            modelContext.insert(created)
            return created
        }()

        record.breakfast = breakfast.trimmingCharacters(in: .whitespacesAndNewlines)
        record.lunch = lunch.trimmingCharacters(in: .whitespacesAndNewlines)
        record.clothing = clothing.trimmingCharacters(in: .whitespacesAndNewlines)

        let reminder = standingReminder.trimmingCharacters(in: .whitespacesAndNewlines)
        record.standingReminder = reminder.isEmpty ? nil : reminder

        try? modelContext.save()
    }
}
