import SwiftUI
import SwiftData

struct KidsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @State private var isPresentingAddKid = false
    @Query private var dayDefaults: [KidDayDefaults]

    private func hasDefaults(for kid: KidRecord) -> Bool {
        dayDefaults.contains {
            $0.kidID == kid.id
                && !($0.breakfast.isEmpty && $0.lunch.isEmpty && $0.clothing.isEmpty)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if kids.isEmpty {
                    ContentUnavailableView(
                        "No kids yet",
                        systemImage: "person.badge.plus",
                        description: Text("Add a kid, then add their school under the Schools tab.")
                    )
                } else {
                    List {
                        ForEach(kids) { kid in
                            NavigationLink {
                                KidDefaultsView(kid: kid)
                            } label: {
                                HStack {
                                    Circle().fill(Color(hex: kid.colorHex)).frame(width: 12, height: 12)
                                    Text(kid.name)
                                    Spacer()
                                    if !hasDefaults(for: kid) {
                                        // Morning Mode is only as good as the
                                        // baseline behind it, and a kid with no
                                        // defaults would render as four blank
                                        // fields with no hint why.
                                        Text("Set up day")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .onDelete(perform: deleteKids)
                    }
                }
            }
            .navigationTitle("Kids")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { isPresentingAddKid = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $isPresentingAddKid) {
                AddKidView()
            }
        }
    }

    private func deleteKids(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(kids[index]) }
        try? modelContext.save()
    }
}
