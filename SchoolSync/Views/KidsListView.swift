import SwiftUI
import SwiftData

struct KidsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @State private var isPresentingAddKid = false

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
                            HStack {
                                Circle().fill(Color(hex: kid.colorHex)).frame(width: 12, height: 12)
                                Text(kid.name)
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
