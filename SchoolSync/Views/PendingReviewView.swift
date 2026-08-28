import SwiftUI
import SwiftData

/// Reviews whatever the Ingest backend has received since the last check
/// (see INGEST_BACKEND.md) — the in-app equivalent of the share extension's
/// `ShareConfirmationView`, just sourced from a network poll instead of the
/// App Group queue. Nothing here runs unless `IngestSettings.isConfigured`.
struct PendingReviewView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @Query(sort: \SchoolRecord.name) private var schools: [SchoolRecord]

    @State private var emails: [PendingForwardedEmail] = []
    @State private var eventsByEmail: [String: [PendingCandidateEvent]] = [:]
    @State private var exceptionsByEmail: [String: [PendingCandidateException]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && emails.isEmpty {
                ProgressView()
            } else if let errorMessage {
                ContentUnavailableView("Couldn't reach the backend", systemImage: "wifi.slash", description: Text(errorMessage))
            } else if emails.isEmpty {
                ContentUnavailableView("Nothing pending", systemImage: "checkmark.circle", description: Text("Everything the backend has received so far has already been reviewed."))
            } else {
                List(emails) { email in
                    NavigationLink {
                        PendingEmailConfirmView(
                            email: email,
                            candidates: eventsByEmail[email.id] ?? [],
                            exceptions: exceptionsByEmail[email.id] ?? [],
                            kids: kids,
                            schools: schools,
                            onSave: { kidID, schoolID, checkedEventIDs in
                                await save(email: email, kidID: kidID, schoolID: schoolID, checkedEventIDs: checkedEventIDs)
                            }
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(email.subject).lineLimit(1)
                            Text(email.receivedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Pending Emails")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        guard let client = IngestClient.configured() else {
            errorMessage = "Set a Backend URL and API Key in Settings first."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await client.fetchPending()
            emails = response.emails
            eventsByEmail = Dictionary(grouping: response.events, by: \.forwardedEmailId)
            exceptionsByEmail = Dictionary(grouping: response.exceptions ?? [], by: \.forwardedEmailId)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Writes day exceptions into the local store.
    ///
    /// Upserted by identity rather than inserted, so re-reading a month that
    /// has been corrected once doesn't stack a second opinion about the same
    /// day on top of the first — the same property SchoolEventRecord gets from
    /// externalID.
    ///
    /// A manual edit is never overwritten. If someone fixed a day by hand, a
    /// later document re-stating the original is not new information, and
    /// silently undoing their correction is the fastest way to make the screen
    /// untrustworthy.
    private func saveExceptions(
        _ exceptions: [PendingCandidateException],
        kidID: UUID,
        subject: String
    ) {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        // The day string is a wall-clock date with no zone, so parse it in the
        // device's own calendar rather than UTC — otherwise "pack a lunch on
        // the 9th" lands on the 8th for anyone west of Greenwich.
        formatter.timeZone = calendar.timeZone

        let existing = (try? modelContext.fetch(FetchDescriptor<DayException>())) ?? []

        for exception in exceptions {
            guard let day = formatter.date(from: exception.day) else { continue }
            let startOfDay = calendar.startOfDay(for: day)

            let identity = DayException.identity(
                kidID: kidID,
                day: startOfDay,
                field: exception.dayFieldValue,
                source: .email
            )

            if let manual = existing.first(where: {
                $0.kidID == kidID
                    && calendar.isDate($0.day, inSameDayAs: startOfDay)
                    && $0.field == exception.dayFieldValue
                    && $0.source == .manual
            }) {
                _ = manual
                continue
            }

            if let match = existing.first(where: { $0.id == identity }) {
                match.value = exception.value
                match.provenance = exception.note ?? subject
                match.isNotable = exception.isNotableException
            } else {
                modelContext.insert(
                    DayException(
                        kidID: kidID,
                        day: startOfDay,
                        field: exception.dayFieldValue,
                        value: exception.value,
                        source: .email,
                        provenance: exception.note ?? subject,
                        isNotable: exception.isNotableException
                    )
                )
            }
        }

        try? modelContext.save()
    }

    private func save(email: PendingForwardedEmail, kidID: UUID, schoolID: UUID, checkedEventIDs: Set<String>) async {
        let candidates = eventsByEmail[email.id] ?? []
        let checked = candidates.filter { checkedEventIDs.contains($0.id) }

        let eventDTOs = checked.map { candidate in
            SchoolEventDTO(
                id: "\(schoolID):\(candidate.title):\(candidate.startDate.timeIntervalSince1970)".stableID,
                title: candidate.title,
                startDate: candidate.startDate,
                endDate: candidate.endDate,
                isAllDay: candidate.isAllDayEvent,
                location: nil,
                notes: candidate.notes,
                kidID: kidID,
                schoolID: schoolID,
                source: .emailForward
            )
        }

        let emailDTO = ForwardedEmailDTO(
            id: email.id,
            subject: email.subject,
            bodyText: email.bodyText,
            sharedDate: email.receivedAt,
            kidID: kidID,
            schoolID: schoolID
        )

        let store = EventStore(modelContext: modelContext)
        try? store.upsert(eventDTOs)
        try? store.insertForwardedEmailIfNeeded(emailDTO)

        // Exceptions inherit the kid chosen for the email, the same way events
        // do. The backend has never known which child a document belongs to —
        // that answer lives here, and asking again per-day would be absurd for
        // a lunch calendar covering a month.
        let exceptions = exceptionsByEmail[email.id] ?? []
        saveExceptions(exceptions, kidID: kidID, subject: email.subject)

        if let client = IngestClient.configured() {
            try? await client.acknowledge(
                emailIDs: [email.id],
                eventIDs: checked.map(\.id),
                exceptionIDs: exceptions.map(\.id)
            )
        }

        emails.removeAll { $0.id == email.id }
        eventsByEmail[email.id] = nil
        exceptionsByEmail[email.id] = nil
    }
}

private struct PendingEmailConfirmView: View {
    @Environment(\.dismiss) private var dismiss

    let email: PendingForwardedEmail
    let candidates: [PendingCandidateEvent]
    let exceptions: [PendingCandidateException]
    let kids: [KidRecord]
    let schools: [SchoolRecord]
    let onSave: (UUID, UUID, Set<String>) async -> Void

    @State private var selectedIDs: Set<String>
    @State private var selectedKidID: UUID?
    @State private var selectedSchoolID: UUID?
    @State private var isSaving = false

    init(email: PendingForwardedEmail, candidates: [PendingCandidateEvent], kids: [KidRecord], schools: [SchoolRecord], onSave: @escaping (UUID, UUID, Set<String>) async -> Void) {
        self.email = email
        self.candidates = candidates
        self.kids = kids
        self.schools = schools
        self.onSave = onSave
        _selectedIDs = State(initialValue: Set(candidates.map(\.id)))
    }

    private var eligibleSchools: [SchoolRecord] {
        guard let selectedKidID else { return [] }
        return schools.filter { $0.kidID == selectedKidID && $0.acceptsEmailForwarding }
    }

    private var canSave: Bool { selectedKidID != nil && selectedSchoolID != nil }

    /// An all-day candidate has no meaningful clock time, so don't invent one.
    ///
    /// The backend anchors a date-only event at noon UTC deliberately: naive
    /// midnight renders as the PREVIOUS day in any negative-offset timezone,
    /// which would silently move an event rather than merely look odd. The
    /// cost is that noon UTC reads as "7:00 AM" here — a time the email never
    /// stated. `endDate == nil` is already how this pipeline says "all-day"
    /// (see the isAllDay mapping below), so use it to drop the time entirely.
    private static func dateLabel(for candidate: PendingCandidateEvent) -> String {
        candidate.isAllDayEvent
            ? candidate.startDate.formatted(date: .abbreviated, time: .omitted)
            : candidate.startDate.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Form {
            Section("From") {
                Text(email.subject).font(.headline)
                Text(email.bodyText).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }

            Section("Detected dates") {
                if candidates.isEmpty {
                    Text("No dates found in this email — you can still save it to browse later.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(candidates) { candidate in
                        Button {
                            if selectedIDs.contains(candidate.id) {
                                selectedIDs.remove(candidate.id)
                            } else {
                                selectedIDs.insert(candidate.id)
                            }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.title)
                                    Text(Self.dateLabel(for: candidate))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let notes = candidate.notes {
                                        Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.primary)
                    }
                }
            }

            if !exceptions.isEmpty {
                Section {
                    ForEach(exceptions) { exception in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: exception.isNotableException ? "exclamationmark.circle.fill" : "circle")
                                .font(.caption2)
                                .foregroundStyle(exception.isNotableException ? Color.accentColor : Color.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(exception.day) · \(exception.dayFieldValue.label)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(exception.value)
                                    .font(.subheadline)
                                if let note = exception.note, !note.isEmpty {
                                    Text(note).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Daily changes")
                } footer: {
                    // Not individually checkable, unlike events. A lunch
                    // calendar is twenty days of the same answer and ticking
                    // each one would be worse than useless; they save together
                    // with the kid chosen below, and any day can be corrected
                    // afterwards.
                    Text("Saved together for the kid you choose below. A marked line needs your attention; an unmarked one just fills in that day's detail.")
                }
            }

            Section("Assign to") {
                if kids.isEmpty {
                    Text("Add a kid in SchoolSync first.").foregroundStyle(.secondary)
                } else {
                    Picker("Kid", selection: $selectedKidID) {
                        Text("None").tag(UUID?.none)
                        ForEach(kids) { kid in Text(kid.name).tag(Optional(kid.id)) }
                    }
                    if eligibleSchools.isEmpty {
                        Text("No school for this kid accepts forwarded emails yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("School", selection: $selectedSchoolID) {
                            Text("None").tag(UUID?.none)
                            ForEach(eligibleSchools) { school in Text(school.name).tag(Optional(school.id)) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard let kidID = selectedKidID, let schoolID = selectedSchoolID else { return }
                    isSaving = true
                    Task {
                        await onSave(kidID, schoolID, selectedIDs)
                        dismiss()
                    }
                } label: {
                    if isSaving { ProgressView() } else { Text("Save") }
                }
                .disabled(!canSave || isSaving)
            }
        }
        .onAppear {
            if selectedKidID == nil { selectedKidID = kids.first?.id }
        }
    }
}
