import SwiftUI
import SwiftData

/// Three screens, not five.
///
/// Kids, Schools and Emails were tabs of equal standing with the calendar, but
/// they are all setup and history — things you touch when something changes,
/// not on a school morning. Giving them permanent real estate pushed the one
/// screen this app exists for into a tab bar full of maintenance.
///
/// They keep their views and move under Settings, so nothing became
/// unreachable; only the ranking changed.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppearanceSetting.storageKey, store: AppGroup.sharedDefaults)
    private var appearanceRaw = AppearanceSetting.system.rawValue

    @State private var isAutoSyncing = false

    var body: some View {
        TabView {
            MorningModeView()
                .tabItem { Label("Morning", systemImage: "sun.horizon") }

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // Applied here rather than per-screen: preferredColorScheme propagates
        // up to the window, so one modifier at the root also covers every
        // sheet and pushed view beneath it.
        .preferredColorScheme(AppearanceSetting.resolve(appearanceRaw).colorScheme)
        .task { await autoSyncIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the app after it's been away is the moment its
            // contents are most likely to be stale, and the moment someone is
            // about to read them.
            guard phase == .active else { return }
            Task { await autoSyncIfNeeded() }
        }
    }

    /// Syncs on open, so nobody has to know the Sync button exists.
    ///
    /// Fire-and-forget by design: nothing here blocks the UI or reports
    /// anything. SwiftData queries update themselves when rows land, so the
    /// screen fills in behind whatever is already on it, and a failure leaves
    /// the last known state visible rather than an error over the top of it.
    /// The sync result is still recorded for Settings, which is where someone
    /// goes when they suspect something is wrong.
    private func autoSyncIfNeeded() async {
        guard !isAutoSyncing, AutoSync.shouldRun() else { return }
        isAutoSyncing = true
        defer { isAutoSyncing = false }

        let coordinator = SyncCoordinator(
            modelContext: modelContext,
            calendarSyncService: CalendarSyncService()
        )
        _ = await coordinator.runFullSync()
        AutoSync.markRun()
    }
}

#Preview {
    ContentView()
}
