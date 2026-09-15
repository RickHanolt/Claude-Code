import SwiftUI

/// Setting the town, once.
///
/// A search-and-pick rather than a free-text field: two towns share a name more
/// often than you'd think, and silently forecasting for the wrong Springfield
/// is exactly the sort of quiet wrongness this app is supposed to avoid.
struct WeatherPlaceView: View {
    @AppStorage(WeatherSettings.placeKey, store: AppGroup.sharedDefaults)
    private var placeData = Data()

    @State private var query = ""
    @State private var matches: [WeatherService.PlaceMatch] = []
    @State private var isSearching = false
    @State private var searched = false
    @State private var error: String?

    private var place: WeatherPlace? { WeatherSettings.place(fromStored: placeData) }

    var body: some View {
        Form {
            Section {
                if let place {
                    HStack {
                        Text(place.label)
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                    Button("Remove", role: .destructive) {
                        WeatherSettings.place = nil
                    }
                } else {
                    Text("No town set yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Current")
            } footer: {
                Text("Weather is shown for this town on every phone following this schedule — so whoever has the kids sees the weather the kids are actually in.")
            }

            Section {
                HStack {
                    TextField("Town or city", text: $query)
                        .autocorrectionDisabled()
                        .onSubmit { Task { await search() } }
                    Button("Search") { Task { await search() } }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }

                if isSearching {
                    HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) }
                } else if searched && matches.isEmpty {
                    Text("Nothing found. Try the nearest larger town.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ForEach(matches) { match in
                    Button {
                        select(match.place)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.place.name).foregroundStyle(.primary)
                            if let region = match.place.region, !region.isEmpty {
                                Text(region).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Find a town")
            }

            if let error {
                Section { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Weather")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false; searched = true }

        do {
            matches = try await WeatherService.search(query)
            error = nil
        } catch {
            self.error = "Couldn't search — \(error.localizedDescription)"
            matches = []
        }
    }

    private func select(_ chosen: WeatherPlace) {
        WeatherSettings.place = chosen
        matches = []
        query = ""
        searched = false
        // Fetched immediately rather than on the next sync, so the choice is
        // confirmed by a forecast appearing rather than by a checkmark.
        Task { await WeatherService.refreshIfNeeded(force: true) }
    }
}
