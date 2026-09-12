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

    @AppStorage(AutoAcceptSetting.storageKey, store: AppGroup.sharedDefaults)
    private var autoAcceptRoutedMail = true

    @Query private var allEvents: [SchoolEventRecord]
    @Query private var allExceptions: [DayException]
    @Query private var allRoutes: [SenderRoute]

    @State private var showResetConfirm = false
    @State private var isResetting = false

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
                    NavigationLink { SendersListView() } label: {
                        Label("Senders", systemImage: "tray.and.arrow.down")
                    }
                    NavigationLink { DayExceptionsView() } label: {
                        Label("Day changes", systemImage: "calendar.badge.exclamationmark")
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
                        ForEach(result.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.secondary)
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

                Section {
                    Toggle("File mail from known senders automatically", isOn: $autoAcceptRoutedMail)
                } footer: {
                    Text("Once you've assigned an email from an address to a kid, later mail from that address is saved without asking. The first email from any new sender is always reviewed by hand.")
                }

                Section {
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        if isResetting {
                            ProgressView()
                        } else {
                            Text("Start the calendar over")
                        }
                    }
                    .disabled(isResetting)
                } header: {
                    Text("Start over")
                } footer: {
                    Text("Clears every event, every day change, and everything the app has learned about senders — including from your Calendar app. Kids, schools, normal days and your backend settings are kept. Nothing is re-extracted: feeds reload on the next sync, and forwarded emails can be reviewed again from the backend, which still holds them.")
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
                "Start the calendar over?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(allEvents.count) event(s) and \(allExceptions.count) day change(s)", role: .destructive) {
                    resetCalendar()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Kids, schools and normal days are kept. Events already written into your Calendar app are removed too. Anything that came from a feed returns on the next sync; anything that came by email has to be reviewed again.")
            }
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

    /// Wipes what was derived, keeps what was configured.
    ///
    /// The distinction is the whole point: kids, schools, normal days and
    /// backend credentials were typed in by hand and are still correct. Events
    /// and day changes were derived from documents, and a document filed under
    /// the wrong child poisons everything downstream of it in a way that is
    /// tedious to unpick row by row.
    ///
    /// Sender routes go too. They are also learned, and a route pointing at
    /// the wrong kid would auto-file the very documents being re-reviewed
    /// straight back into the mess this is clearing.
    ///
    /// Nothing is re-extracted. The backend still holds every candidate event
    /// and exception it ever produced — acknowledging them marked them
    /// consumed, it didn't delete them — so rebuilding costs a sync, not
    /// another model call.
    private func resetCalendar() {
        isResetting = true
        defer { isResetting = false }

        let calendarSync = CalendarSyncService()

        for event in allEvents {
            // Remove the copy in the iOS calendar first. The sync only ever
            // adds and updates, so an EKEvent whose record is gone would stay
            // there permanently with nothing left pointing at it.
            if let identifier = event.calendarSyncIdentifier {
                try? calendarSync.delete(eventIdentifier: identifier)
            }
            modelContext.delete(event)
        }

        for exception in allExceptions { modelContext.delete(exception) }
        for route in allRoutes { modelContext.delete(route) }

        try? modelContext.save()
        lastResult = nil
    }

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        let coordinator = SyncCoordinator(modelContext: modelContext, calendarSyncService: CalendarSyncService())
        lastResult = await coordinator.runFullSync()
        // Counts against the automatic interval too, so opening the app right
        // after a manual sync doesn't immediately run a second one.
        AutoSync.markRun()
    }
}
