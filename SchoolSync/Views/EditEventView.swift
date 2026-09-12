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

    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @Query(sort: \SchoolRecord.name) private var schools: [SchoolRecord]

    let event: SchoolEventRecord
    let kid: KidRecord?

    @State private var title: String
    @State private var isAllDay: Bool
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var location: String
    @State private var notes: String
    @State private var errorMessage: String?

    /// Which child this event belongs to.
    ///
    /// Editable because a whole document can land on the wrong one. A Pulaski
    /// semester calendar assigned to the wrong kid put its closures under a
    /// school that never closed on those days, and without this the only
    /// remedy was deleting each event and paying to extract the document
    /// again.
    @State private var kidID: UUID
    @State private var schoolID: UUID

    init(event: SchoolEventRecord, kid: KidRecord?) {
        self.event = event
        self.kid = kid
        _title = State(initialValue: event.title)
        _isAllDay = State(initialValue: event.isAllDay)
        _startDate = State(initialValue: event.startDate)
        _endDate = State(initialValue: event.endDate ?? event.startDate.addingTimeInterval(3600))
        _location = State(initialValue: event.location ?? "")
        _notes = State(initialValue: event.notes ?? "")
        _kidID = State(initialValue: event.kidID)
        _schoolID = State(initialValue: event.schoolID)
    }

    private var eligibleSchools: [SchoolRecord] {
        schools.filter { $0.kidID == kidID }
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
                // Shown for all-day events too, without a time. A school
                // closure can run several days — the CPS calendar's emergency
                // days do — and hiding the end date meant a multi-day event
                // was indistinguishable from a single one.
                DatePicker(
                    "Ends",
                    selection: $endDate,
                    in: startDate...,
                    displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
                )
                TextField("Location", text: $location)
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 100)
            }

            Section {
                Picker("Kid", selection: $kidID) {
                    ForEach(kids) { kid in Text(kid.name).tag(kid.id) }
                }
                if eligibleSchools.isEmpty {
                    Text("That kid has no schools set up yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("School", selection: $schoolID) {
                        ForEach(eligibleSchools) { school in Text(school.name).tag(school.id) }
                    }
                }
            } header: {
                Text("Assign to")
            } footer: {
                Text("Changing the kid moves this event to their calendar and removes it from the other one.")
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
                    .disabled(!canSave)
            }
        }
        .onChange(of: kidID) { _, _ in
            // A school belongs to one kid, so changing the kid invalidates the
            // school. Pick the only one it could be, or clear it and make the
            // user say.
            if !eligibleSchools.contains(where: { $0.id == schoolID }) {
                schoolID = eligibleSchools.first?.id ?? schoolID
            }
        }
    }

    private var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return eligibleSchools.contains { $0.id == schoolID }
    }

    private func save() {
        event.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        event.isAllDay = isAllDay
        event.startDate = startDate
        // Never discard a range. This previously wrote nil for every all-day
        // event, so opening a three-day closure and tapping Save — with the
        // end date not even on screen — silently shortened it to one day.
        //
        // Still nil when start and end are the same day, so an ordinary
        // one-day event doesn't acquire a span it never had.
        if isAllDay {
            event.endDate = Calendar.current.isDate(endDate, inSameDayAs: startDate) ? nil : endDate
        } else {
            event.endDate = endDate
        }
        let trimmedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        event.location = trimmedLocation.isEmpty ? nil : trimmedLocation
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        event.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        event.isUserEdited = true

        // Moving a kid means the copy already written into the old kid's
        // iOS calendar has to go, or it lingers there forever: the sync only
        // adds and updates, and would never revisit an event that is no longer
        // in that kid's set. Clearing the identifier lets the next sync create
        // it fresh in the new kid's calendar.
        if kidID != event.kidID {
            if let identifier = event.calendarSyncIdentifier {
                try? CalendarSyncService().delete(eventIdentifier: identifier)
            }
            event.calendarSyncIdentifier = nil
        }

        event.kidID = kidID
        event.schoolID = schoolID

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
