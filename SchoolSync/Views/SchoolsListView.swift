import SwiftUI
import SwiftData

struct SchoolsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SchoolRecord.name) private var schools: [SchoolRecord]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @State private var isPresentingAddSchool = false

    private var kidsByID: [UUID: KidRecord] { Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) }) }

    var body: some View {
        NavigationStack {
            Group {
                if kids.isEmpty {
                    ContentUnavailableView(
                        "Add a kid first",
                        systemImage: "person.badge.plus",
                        description: Text("Schools are attached to a kid — add a kid under the Kids tab first.")
                    )
                } else if schools.isEmpty {
                    ContentUnavailableView(
                        "No schools yet",
                        systemImage: "building.columns",
                        description: Text("Add a school and configure how it publishes events.")
                    )
                } else {
                    List {
                        ForEach(schools) { school in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(school.name).font(.body)
                                Text(kidsByID[school.kidID]?.name ?? "Unknown kid")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    if school.icsFeedURL != nil {
                                        Label("ICS feed", systemImage: "dot.radiowaves.up.forward")
                                    }
                                    if school.scrapeURL != nil {
                                        Label("Scrape", systemImage: "text.viewfinder")
                                    }
                                    if school.acceptsEmailForwarding {
                                        Label("Email", systemImage: "envelope")
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            }
                        }
                        .onDelete(perform: deleteSchools)
                    }
                }
            }
            .navigationTitle("Schools")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isPresentingAddSchool = true } label: { Image(systemName: "plus") }
                        .disabled(kids.isEmpty)
                }
            }
            .sheet(isPresented: $isPresentingAddSchool) {
                AddSchoolView(kids: kids)
            }
        }
    }

    private func deleteSchools(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(schools[index]) }
        try? modelContext.save()
    }
}
