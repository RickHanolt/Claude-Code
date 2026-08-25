import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var isSyncing = false
    @State private var lastResult: SyncResult?
    @State private var calendarAccessGranted: Bool?

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
                        ForEach(result.errors, id: \.self) { error in
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
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

    private func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        let coordinator = SyncCoordinator(modelContext: modelContext, calendarSyncService: CalendarSyncService())
        lastResult = await coordinator.runFullSync()
    }
}
