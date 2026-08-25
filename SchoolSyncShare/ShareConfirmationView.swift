import SwiftUI
import SwiftData

/// Lets the user review the dates `EmailParserService` found in a
/// forwarded/shared email, pick which ones are real events, and assign a
/// kid + school before anything is written to `SharedEventQueue`. Reads
/// kids/schools from the same App-Group-backed SwiftData store the main app
/// uses, so newly-added kids/schools show up here without any extra sync
/// step.
struct ShareConfirmationView: View {
    let subject: String
    let candidates: [ParsedCandidateEvent]
    let onSave: ([SchoolEventDTO]) -> Void
    let onCancel: () -> Void

    @State private var selectedIDs: Set<UUID>
    @State private var selectedKidID: UUID?
    @State private var selectedSchoolID: UUID?

    @State private var kids: [KidRecord] = []
    @State private var schools: [SchoolRecord] = []

    private let modelContainer: ModelContainer?

    init(
        subject: String,
        candidates: [ParsedCandidateEvent],
        onSave: @escaping ([SchoolEventDTO]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.subject = subject
        self.candidates = candidates
        self.onSave = onSave
        self.onCancel = onCancel
        _selectedIDs = State(initialValue: Set(candidates.map(\.id)))

        let schema = Schema([KidRecord.self, SchoolRecord.self, SchoolEventRecord.self])
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

                if candidates.isEmpty {
                    Section {
                        Text("No dates found in this email. Nothing to save.")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Detected dates") {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
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
        !selectedIDs.isEmpty && selectedKidID != nil && selectedSchoolID != nil
    }

    private func loadKidsAndSchools() {
        guard let context = modelContainer?.mainContext else { return }
        kids = (try? context.fetch(FetchDescriptor<KidRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
        schools = (try? context.fetch(FetchDescriptor<SchoolRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
        if selectedKidID == nil { selectedKidID = kids.first?.id }
    }

    private func save() {
        guard let kidID = selectedKidID, let schoolID = selectedSchoolID else { return }
        let dtos: [SchoolEventDTO] = candidates
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
        onSave(dtos)
    }
}
