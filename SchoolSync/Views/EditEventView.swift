import SwiftUI
import SwiftData

/// Lets you fix a bad title, wrong date, or other detail on an existing
/// event — most useful for ICS/scrape/email-parsed events that came out
/// slightly wrong — without deleting and waiting for the next sync to bring
/// it back correctly (it might not). Marks the record `isUserEdited` so a
/// future sync from the same source won't silently overwrite the fix; see
/// `EventStore.upsert`.
struct EditEventView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let event: SchoolEventRecord
    let kid: KidRecord?

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var location: String
    @State private var notes: String
    @State private var errorMessage: String?

    init(event: SchoolEventRecord, kid: KidRecord?) {
        self.event = event
        self.kid = kid
        _title = State(initialValue: event.title)
        _isAllDay = State(initialValue: event.isAllDay)
        _startDate = State(initialValue: event.startDate)
        _endDate = State(initialValue: event.endDate ?? event.startDate.addingTimeInterval(3600))
        _location = State(initialValue: event.location ?? "")
        _notes = State(initialValue: event.notes ?? "")
    }

    var body: some View {
        Form {
            Section("Event") {
                TextField("Title", text: $title)
                Toggle("All day", isOn: $isAllDay)
                DatePicker(
                    "Starts",
                    selection: $startDate,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                if !isAllDay {
                    DatePicker("Ends", selection: $endDate, in: startDate..., displayedComponents: [.date, .hourAndMinute])
                }
                TextField("Location", text: $location)
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 100)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .navigationTitle("Edit Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func save() {
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.isAllDay = isAllDay
        event.startDate = startDate
        event.endDate = isAllDay ? nil : endDate
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = trimmedLocation.isEmpty ? nil : trimmedLocation
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        event.isUserEdited = true

        do {
            try modelContext.save()
            if let kid {
                try CalendarSyncService().sync(events: [event], kid: kid, modelContext: modelContext)
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
