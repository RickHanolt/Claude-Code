import SwiftUI
import SwiftData

struct SchoolsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SchoolRecord.name) private var schools: [SchoolRecord]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    /// One sheet, two purposes.
    ///
    /// Two separate `.sheet` modifiers on the same view have a long history of
    /// only the last one working, and that's not something this project can
    /// test before it's on a device. A single item-driven sheet sidesteps it.
    private enum SchoolSheet: Identifiable {
        case add
        case edit(SchoolRecord)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let school): school.id.uuidString
            }
        }
    }

    @State private var sheet: SchoolSheet?

    private var kidsByID: [UUID: KidRecord] { Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) }) }

    var body: some View {
        Group {
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
                            Button {
                                sheet = .edit(school)
                            } label: {
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

                                    // Show the actual URL, not just that one
                                    // exists. A school was configured with its
                                    // site's news RSS endpoint rather than its
                                    // calendar, and this row said "ICS feed"
                                    // the whole time — the one fact that would
                                    // have given it away was the one fact not
                                    // on screen.
                                    if let feed = school.icsFeedURLString, !feed.isEmpty {
                                        Text(feed)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete(perform: deleteSchools)
                    }
                }
            }
            .navigationTitle("Schools")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { sheet = .add } label: { Image(systemName: "plus") }
                        .disabled(kids.isEmpty)
                }
            }
            .sheet(item: $sheet) { item in
                switch item {
                case .add:
                    AddSchoolView(kids: kids)
                case .edit(let school):
                    AddSchoolView(kids: kids, existing: school)
                }
            }
        }
    }

    private func deleteSchools(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(schools[index]) }
        try? modelContext.save()
    }
}
