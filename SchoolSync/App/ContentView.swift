import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }

            KidsListView()
                .tabItem { Label("Kids", systemImage: "person.2") }

            SchoolsListView()
                .tabItem { Label("Schools", systemImage: "building.columns") }

            EmailsListView()
                .tabItem { Label("Emails", systemImage: "envelope") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}

#Preview {
    ContentView()
}
