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

    var body: some View {
        NavigationStack {
            Form {
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
