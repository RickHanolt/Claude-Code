import SwiftUI

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
    var body: some View {
        TabView {
            MorningModeView()
                .tabItem { Label("Morning", systemImage: "sun.horizon") }

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview {
    ContentView()
}
