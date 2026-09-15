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

    /// Watched rather than read once, because every transition into and out of
    /// viewer mode writes it — so this is what swaps the whole app over the
    /// moment someone joins a household or leaves one.
    @AppStorage(ViewerSettings.hasChosenRoleKey) private var hasChosenRole = false

    @Query private var kids: [KidRecord]

    @State private var isAutoSyncing = false

    /// Only a genuinely blank install gets asked. An app with kids in it has
    /// already answered, and so has one with backend credentials or a viewer
    /// token — asking either of them to choose would be alarming and wrong.
    private var needsWelcome: Bool {
        !hasChosenRole && kids.isEmpty && ViewerSettings.role == .unconfigured
    }

    private var isViewer: Bool { ViewerSettings.role == .viewer }

    var body: some View {
        Group {
            if needsWelcome {
                WelcomeView()
            } else {
                tabs
            }
        }
        // Applied here rather than per-screen: preferredColorScheme propagates
        // up to the window, so one modifier at the root also covers every
        // sheet and pushed view beneath it.
        .preferredColorScheme(AppearanceSetting.resolve(appearanceRaw).colorScheme)
        .environment(\.isViewer, isViewer)
        .task { await autoSyncIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            // Returning to the app after it's been away is the moment its
            // contents are most likely to be stale, and the moment someone is
            // about to read them.
            guard phase == .active else { return }
            Task { await autoSyncIfNeeded() }
        }
    }

    private var tabs: some View {
        TabView {
            MorningModeView()
                .tabItem { Label("Morning", systemImage: "sun.horizon") }

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            // Two different screens, not one with rows hidden — see
            // ViewerSettingsView for why.
            if isViewer {
                ViewerSettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            } else {
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
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

        let snapshots = SnapshotService(modelContext: modelContext)

        switch ViewerSettings.role {
        case .viewer:
            // A viewer's entire sync. No feeds, no backend queue, no calendar
            // writes — its only source of truth is what the owner published,
            // and fetching a school's feed itself would immediately drift from
            // the snapshot it is meant to be mirroring.
            try? await snapshots.refreshFromSnapshot(calendarSync: CalendarSyncService())

        case .owner, .unconfigured:
            let coordinator = SyncCoordinator(
                modelContext: modelContext,
                calendarSyncService: CalendarSyncService()
            )
            _ = await coordinator.runFullSync()

            // After, not before: a snapshot published from a half-synced store
            // would show viewers yesterday's calendar with today's timestamp.
            await snapshots.publishIfNeeded(hasViewers: ViewerSettings.hasViewers)
        }

        // After either branch, because a viewer's town arrives with the
        // snapshot and fetching a forecast before it lands would fetch one for
        // the wrong place — or for nowhere at all on the very first sync.
        await WeatherService.refreshIfNeeded()

        AutoSync.markRun()
    }
}

#Preview {
    ContentView()
}
