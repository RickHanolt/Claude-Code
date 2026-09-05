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
    @Query private var senderRoutes: [SenderRoute]

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
                            suggestion: route(for: email),
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

    /// What this sender's mail turned out to be about last time.
    ///
    /// Only a suggestion: it pre-fills the pickers, which stay editable, and
    /// a stale route pointing at a deleted kid or a school that no longer
    /// belongs to them is discarded here rather than offered.
    private func route(for email: PendingForwardedEmail) -> SenderRoute? {
        guard let sender = SenderRoute.normalize(email.sender),
              let match = senderRoutes.first(where: { $0.sender == sender }),
              kids.contains(where: { $0.id == match.kidID }),
              schools.contains(where: { $0.id == match.schoolID && $0.kidID == match.kidID })
        else { return nil }

        return match
    }

    /// Remembers the choice so the next email from this sender arrives with
    /// the answer already filled in.
    ///
    /// Written on save rather than on selection: a kid picked and then changed
    /// before saving was never the answer, and learning from it would teach the
    /// app a choice the user visibly rejected.
    private func rememberRoute(sender: String?, kidID: UUID, schoolID: UUID) {
        guard let sender = SenderRoute.normalize(sender) else { return }

        if let existing = senderRoutes.first(where: { $0.sender == sender }) {
            existing.kidID = kidID
            existing.schoolID = schoolID
            existing.updatedAt = .now
        } else {
            modelContext.insert(SenderRoute(sender: sender, kidID: kidID, schoolID: schoolID))
        }

        try? modelContext.save()
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

        rememberRoute(sender: email.sender, kidID: kidID, schoolID: schoolID)

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

    /// What this sender's mail meant last time, or nil if it's never been
    /// assigned. Pre-fills the pickers; it does not bypass them.
    let suggestion: SenderRoute?

    let onSave: (UUID, UUID, Set<String>) async -> Void

    @State private var selectedIDs: Set<String>
    @State private var selectedKidID: UUID?
    @State private var selectedSchoolID: UUID?
    @State private var isSaving = false

    // Hand-written because `_selectedIDs` has to be seeded from `candidates`,
    // which suppresses the memberwise initializer — so every stored property
    // added above must be assigned here too. Adding `exceptions` and missing
    // this line is what broke the iOS build on 1580267.
    init(
        email: PendingForwardedEmail,
        candidates: [PendingCandidateEvent],
        exceptions: [PendingCandidateException],
        kids: [KidRecord],
        schools: [SchoolRecord],
        suggestion: SenderRoute?,
        onSave: @escaping (UUID, UUID, Set<String>) async -> Void
    ) {
        self.email = email
        self.candidates = candidates
        self.exceptions = exceptions
        self.kids = kids
        self.schools = schools
        self.suggestion = suggestion
        self.onSave = onSave
        _selectedIDs = State(initialValue: Set(candidates.map(\.id)))
        _selectedKidID = State(initialValue: suggestion?.kidID)
        _selectedSchoolID = State(initialValue: suggestion?.schoolID)
    }

    private var eligibleSchools: [SchoolRecord] {
        guard let selectedKidID else { return [] }
        return schools.filter { $0.kidID == selectedKidID && $0.acceptsEmailForwarding }
    }

    private var canSave: Bool { selectedKidID != nil && selectedSchoolID != nil }

    /// Choose the school when there's only one it could be.
    ///
    /// School exists to attribute *events*, and a lunch calendar produces none
    /// — so the picker was gating Save on an answer that didn't apply to the
    /// document being reviewed. The principled fix is to stop requiring it,
    /// but schoolID is a non-optional stored property on ForwardedEmailRecord
    /// and this project has no SwiftData migration plan yet. Removing the
    /// unnecessary question is worth less than the risk of a model change, so
    /// this answers it instead when the answer is forced.
    private func autoSelectSingleSchool() {
        let options = eligibleSchools

        // Idempotent on purpose: a school already chosen — by the user, or
        // carried in from this sender's remembered route — is left alone, so
        // this can run on appear and on every kid change without fighting
        // whatever set it.
        if let current = selectedSchoolID, options.contains(where: { $0.id == current }) {
            return
        }

        if options.count == 1 {
            selectedSchoolID = options[0].id
            return
        }

        // Switching kids can leave the previous kid's school selected, which
        // would silently file the email under a school it has nothing to do
        // with.
        if let current = selectedSchoolID, !options.contains(where: { $0.id == current }) {
            selectedSchoolID = nil
        }
    }

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
                // An attachment that never reached the model is reported even
                // when the body did produce dates: an email can carry a
                // newsletter that parsed fine and a calendar image that didn't,
                // and the half that worked shouldn't conceal the half that
                // didn't.
                if let note = email.attachmentNote {
                    Label {
                        Text(note).font(.caption)
                    } icon: {
                        Image(systemName: "paperclip.badge.ellipsis")
                    }
                    .foregroundStyle(.secondary)
                }

                if candidates.isEmpty {
                    // Three different situations used to print the same
                    // sentence. "No dates found" is a confident claim, and it
                    // was being made about emails that had failed to extract
                    // and about attachments nothing had ever looked at.
                    if email.isStillExtracting {
                        Text("Still reading this email — check back in a moment.")
                            .foregroundStyle(.secondary)
                    } else if let error = email.extractionError {
                        Text("Couldn't read this email: \(error)")
                            .foregroundStyle(.secondary)
                    } else if !exceptions.isEmpty {
                        // "No dates found" printed directly above two daily
                        // changes reads as a contradiction. Nothing went on the
                        // calendar, but something was certainly found.
                        Text("Nothing for the calendar — what this one carries is in Daily changes below.")
                            .foregroundStyle(.secondary)
                    } else if email.attachmentNote != nil {
                        Text("Nothing found in the message text, and the attachment above wasn't readable.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No dates found in this email — you can still save it to browse later.")
                            .foregroundStyle(.secondary)
                    }
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

                    // Say where a pre-filled answer came from. An app that
                    // silently fills in a child's name is one you have to
                    // double-check every time; one that says why it guessed is
                    // one you can trust at a glance and correct when it's
                    // wrong.
                    if let suggestion, selectedKidID == suggestion.kidID {
                        Text("Filled in from the last email you assigned from this sender.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Review")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { autoSelectSingleSchool() }
        .onChange(of: selectedKidID) { _, _ in autoSelectSingleSchool() }
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
