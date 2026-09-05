import SwiftUI
import SwiftData

/// Lets the user review the dates `EmailParserService` found in a
/// forwarded/shared email, pick which ones are real events, and assign a
/// kid + school before anything is written to the shared queues. Reads
/// kids/schools from the same App-Group-backed SwiftData store the main app
/// uses, so newly-added kids/schools show up here without any extra sync
/// step.
///
/// Saving always stores the full original email (for the Emails tab),
/// independent of whether any date candidates were found or checked — the
/// checked candidates additionally become calendar events.
struct ShareConfirmationView: View {
    let subject: String
    let bodyText: String
    let candidates: [ParsedCandidateEvent]
    let onSave: ([SchoolEventDTO], ForwardedEmailDTO) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<UUID>
    @State private var selectedKidID: UUID?
    @State private var selectedSchoolID: UUID?

    @State private var kids: [KidRecord] = []
    @State private var schools: [SchoolRecord] = []

    /// Read-only here — the extension honours the app's setting but has no
    /// business changing it, and there's nowhere sensible to offer the choice
    /// inside a share sheet.
    @AppStorage(AppearanceSetting.storageKey, store: AppGroup.sharedDefaults)
    private var appearanceRaw = AppearanceSetting.system.rawValue

    private let modelContainer: ModelContainer?

    init(
        subject: String,
        bodyText: String,
        candidates: [ParsedCandidateEvent],
        onSave: @escaping ([SchoolEventDTO], ForwardedEmailDTO) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.subject = subject
        self.bodyText = bodyText
        self.candidates = candidates
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedIDs = State(initialValue: Set(candidates.map(\.id)))

        // Must list every model in the store, not just the ones this
        // extension writes: the container is opened against the same App Group
        // file as the main app, and a schema missing a model that exists on
        // disk fails to open at all.
        let schema = Schema([
            KidRecord.self,
            SchoolRecord.self,
            SchoolEventRecord.self,
            ForwardedEmailRecord.self,
            KidDayDefaults.self,
            DayException.self,
            SenderRoute.self,
        ])
        let configuration = ModelConfiguration(schema: schema, url: AppGroup.sharedModelStoreURL)
        self.modelContainer = try? ModelContainer(for: schema, configurations: [configuration])
    }

    private var eligibleSchools: [SchoolRecord] {
        guard let selectedKidID else { return [] }
        return schools.filter { $0.kidID == selectedKidID && $0.acceptsEmailForwarding }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("From") {
                    Text(subject).font(.headline)
                }

                Section("Detected dates") {
                    if candidates.isEmpty {
                        Text("No dates found in this email — you can still save it to browse later.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }

                Section("Assign to") {
                    if kids.isEmpty {
                        Text("Add a kid in SchoolSync first.").foregroundStyle(.secondary)
                    } else {
                        Picker("Kid", selection: $selectedKidID) {
                            ForEach(kids) { kid in Text(kid.name).tag(Optional(kid.id)) }
                        }
                        if eligibleSchools.isEmpty {
                            Text("No school for this kid accepts forwarded emails yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("School", selection: $selectedSchoolID) {
                                ForEach(eligibleSchools) { school in Text(school.name).tag(Optional(school.id)) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to SchoolSync")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
            }
            .task { loadKidsAndSchools() }
        }
        .preferredColorScheme(AppearanceSetting.resolve(appearanceRaw).colorScheme)
    }

    private func candidateRow(_ candidate: ParsedCandidateEvent) -> some View {
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
                    Text(candidate.startDate.formatted(date: .abbreviated, time: .shortened))
                        .font(.body)
                    if let notes = candidate.notes {
                        Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var canSave: Bool {
        selectedKidID != nil && selectedSchoolID != nil
    }

    private func loadKidsAndSchools() {
        guard let context = modelContainer?.mainContext else { return }
        kids = (try? context.fetch(FetchDescriptor<KidRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
        schools = (try? context.fetch(FetchDescriptor<SchoolRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
        if selectedKidID == nil { selectedKidID = kids.first?.id }
    }

    private func save() {
        guard let kidID = selectedKidID, let schoolID = selectedSchoolID else { return }

        let eventDTOs: [SchoolEventDTO] = candidates
            .filter { selectedIDs.contains($0.id) }
            .map { candidate in
                SchoolEventDTO(
                    id: "\(schoolID):\(candidate.title):\(candidate.startDate.timeIntervalSince1970)".stableID,
                    title: candidate.title,
                    startDate: candidate.startDate,
                    endDate: candidate.endDate,
                    isAllDay: candidate.endDate == nil,
                    location: nil,
                    notes: candidate.notes,
                    kidID: kidID,
                    schoolID: schoolID,
                    source: .emailForward
                )
            }

        let emailDTO = ForwardedEmailDTO(
            id: UUID().uuidString,
            subject: subject,
            bodyText: bodyText,
            sharedDate: .now,
            kidID: kidID,
            schoolID: schoolID
        )

        onSave(eventDTOs, emailDTO)
    }
}
