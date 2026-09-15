import SwiftUI
import SwiftData

/// Settings for a phone that follows someone else's schedule.
///
/// A separate screen rather than the owner's one with rows hidden. The owner's
/// Settings is nearly all setup — feeds, senders, API keys, "start the calendar
/// over" — and none of it means anything here. Hiding thirty rows to leave four
/// would also mean every row added later has to remember it isn't for viewers.
struct ViewerSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @AppStorage(AppearanceSetting.storageKey, store: AppGroup.sharedDefaults)
    private var appearanceRaw = AppearanceSetting.system.rawValue

    @State private var isRefreshing = false
    @State private var status: String?
    @State private var showLeaveConfirm = false

    /// Watched rather than sampled, so the line updates the instant a refresh
    /// lands instead of freezing at whatever it said when the tab appeared.
    @AppStorage(ViewerSettings.snapshotPublishedAtKey) private var publishedAtRaw = 0.0

    private var publishedAt: Date? { ViewerSettings.date(fromStoredInterval: publishedAtRaw) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(SnapshotFreshness.describe(publishedAt))
                        .foregroundStyle(SnapshotFreshness.isStale(publishedAt) ? Color.orange : Color.secondary)

                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing {
                            ProgressView()
                        } else {
                            Label("Check for updates", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshing)

                    if let status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("This schedule")
                } footer: {
                    Text("Updates arrive when whoever set this up opens their own copy of the app. This phone shows what they last sent, and checks again each time you open it.")
                }

                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceSetting.allCases) { option in
                            Text(option.label).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Button(role: .destructive) {
                        showLeaveConfirm = true
                    } label: {
                        Text("Stop following this schedule")
                    }
                } footer: {
                    Text("Removes the schedule from this phone. You'd need a new code to get it back.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Stop following this schedule?",
                isPresented: $showLeaveConfirm,
                titleVisibility: .visible
            ) {
                Button("Stop following", role: .destructive) { leave() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Everything downloaded to this phone is removed. Ask for a new code to join again.")
            }
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let received = try await SnapshotService(modelContext: modelContext)
                .refreshFromSnapshot(calendarSync: CalendarSyncService())

            status = received
                ? nil
                : "Nothing has been sent yet — they haven't opened their app since sharing it with you."
            AutoSync.markRun()
        } catch {
            // Named, not swallowed. The one failure that matters here is a key
            // that no longer matches, and a viewer who can't see why would just
            // assume the family had a quiet week.
            status = "Couldn't check — \(error.localizedDescription)"
        }
    }

    private func leave() {
        try? SnapshotService(modelContext: modelContext).wipe(calendarSync: CalendarSyncService())
        ViewerSettings.leaveHousehold()
        status = nil
    }
}
