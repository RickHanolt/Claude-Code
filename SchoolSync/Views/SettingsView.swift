import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isSyncing = false
    @State private var lastResult: SyncResult?
    @State private var calendarAccessGranted: Bool?

    @State private var ingestBaseURLText: String = IngestSettings.baseURL?.absoluteString ?? ""
    @State private var ingestAPIKeyText: String = IngestSettings.apiKey ?? ""
    @State private var ingestSaved = false

    @AppStorage(AppearanceSetting.storageKey, store: AppGroup.sharedDefaults)
    private var appearanceRaw = AppearanceSetting.system.rawValue

    @State private var isCleaningUp = false
    @State private var cleanupResult: String?
    @State private var showCleanupConfirm = false

    /// Events still titled with an email's subject line, left behind by the
    /// date-detector parser that predates Claude extraction.
    ///
    /// Matched on the subject prefix rather than on source or date, because
    /// `.emailForward` is also what correctly-extracted events carry — the
    /// prefix is the part no real event title has. Deliberately narrow: leaving
    /// a stale row costs a duplicate, deleting a real one costs an event the
    /// user never sees again.
    @Query(filter: #Predicate<SchoolEventRecord> {
        !$0.isDeletedByUser && ($0.title.starts(with: "Fwd:") || $0.title.starts(with: "Re:"))
    })
    private var staleEvents: [SchoolEventRecord]

    /// Tombstones rather than deletes, for the same reason `CalendarView` does:
    /// a hard delete lets the next sync from the same source re-insert the row,
    /// since the source has no idea the user removed it.
    ///
    /// Skips anything the user has edited. If they took the trouble to fix a
    /// badly-titled event by hand, it isn't stale any more and deleting it
    /// would throw away their work.
    private func cleanUpStaleEvents() {
        isCleaningUp = true
        defer { isCleaningUp = false }

        let calendar = CalendarSyncService()
        var removed = 0

        for event in staleEvents where !event.isUserEdited {
            if let identifier = event.calendarSyncIdentifier {
                try? calendar.delete(eventIdentifier: identifier)
            }
            event.isDeletedByUser = true
            event.calendarSyncIdentifier = nil
            removed += 1
        }

        try? modelContext.save()
        cleanupResult = "Removed \(removed) event\(removed == 1 ? "" : "s")."
    }

    var body: some View {
        NavigationStack {
            Form {
                // Kids, Schools and Emails were tabs of equal standing with
                // the calendar. They're setup and history — touched when
                // something changes, not on a school morning — so they live
                // here now rather than taking permanent space in the tab bar.
                Section("Manage") {
                    NavigationLink { KidsListView() } label: {
                        Label("Kids", systemImage: "person.2")
                    }
                    NavigationLink { SchoolsListView() } label: {
                        Label("Schools", systemImage: "building.columns")
                    }
                    NavigationLink { EmailsListView() } label: {
                        Label("Emails", systemImage: "envelope")
                    }
                }

                Section("Calendar Access") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(calendarAccessGranted == true ? "Granted" : calendarAccessGranted == false ? "Not granted" : "Unknown")
                            .foregroundStyle(.secondary)
                    }
                    Button("Request Calendar Access") {
                        Task { await requestAccess() }
                    }
                }

                Section("Sync") {
                    Button {
                        Task { await sync() }
                    } label: {
                        if isSyncing {
                            ProgressView()
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled(isSyncing)

                    if let result = lastResult {
                        Text("\(result.eventsIngested) events updated")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if result.pendingReviewCount > 0 {
                            Text("\(result.pendingReviewCount) auto-forwarded email(s) waiting for review")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(result.errors, id: \.self) { error in
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section {
                    TextField("Backend URL", text: $ingestBaseURLText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $ingestAPIKeyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save") { saveIngestSettings() }
                    if ingestSaved {
                        Text("Saved.").font(.caption).foregroundStyle(.secondary)
                    }
                    NavigationLink("Check for auto-forwarded emails") {
                        PendingReviewView()
                    }
                    .disabled(!IngestSettings.isConfigured)
                } header: {
                    Text("Auto-forward backend")
                } footer: {
                    Text("Optional — only needed if you set up the auto-forward backend from INGEST_BACKEND.md. Values from step 9 there (the ingestAddress's Worker URL and the apiKey). Leave blank to keep sharing emails manually.")
                }

                if !staleEvents.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            showCleanupConfirm = true
                        } label: {
                            if isCleaningUp {
                                ProgressView()
                            } else {
                                Text("Remove \(staleEvents.count) old-parser event\(staleEvents.count == 1 ? "" : "s")")
                            }
                        }
                        .disabled(isCleaningUp)
                    } header: {
                        Text("Cleanup")
                    } footer: {
                        Text("Events still titled with an email's subject line (\"Fwd: …\"), left over from the parser used before Claude extraction. Removing them here also takes them out of your Calendar app.")
                    }
                }

                if let cleanupResult {
                    Section { Text(cleanupResult).font(.caption).foregroundStyle(.secondary) }
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceSetting.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("About") {
                    Text("App Group: \(AppGroup.identifier)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Scraping and email parsing are heuristic — review new events after the first sync for each school.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Remove \(staleEvents.count) old-parser event\(staleEvents.count == 1 ? "" : "s")?",
                isPresented: $showCleanupConfirm,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) { cleanUpStaleEvents() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This also removes them from your Calendar app. Events you've edited yourself are kept.")
            }
        }
    }

    private func requestAccess() async {
        let service = CalendarSyncService()
        calendarAccessGranted = try? await service.requestAccess()
    }

    private func saveIngestSettings() {
        let trimmedURL = ingestBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = ingestAPIKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        IngestSettings.baseURL = trimmedURL.isEmpty ? nil : URL(string: trimmedURL)
        IngestSettings.apiKey = trimmedKey.isEmpty ? nil : trimmedKey
        ingestSaved = true
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        let coordinator = SyncCoordinator(modelContext: modelContext, calendarSyncService: CalendarSyncService())
        lastResult = await coordinator.runFullSync()
    }
}
