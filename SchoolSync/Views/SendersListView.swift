import SwiftUI
import SwiftData

/// What the app has learned about who sends what, and which senders it should
/// never guess about.
///
/// Sender routing was shipped with no way to see it. That's the same mistake as
/// a school's feed URL being invisible: the app quietly acts on a fact nobody
/// can inspect, and the only symptom of a wrong one is mail filed to the wrong
/// child. This screen is the fact made visible.
struct SendersListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SenderRoute.sender) private var routes: [SenderRoute]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]

    @State private var newAddress = ""
    @State private var addFailed = false

    private var kidsByID: [UUID: KidRecord] { Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) }) }

    /// Exempt addresses with no learned route — typed in before any mail from
    /// them has arrived, which is the whole point of being able to add one.
    private var unroutedExemptions: [String] {
        let routed = Set(routes.map(\.sender))
        return AlwaysAskSenders.all.filter { !routed.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("name@example.com", text: $newAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Add") { addExemption() }
                        .disabled(newAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if addFailed {
                    Text("That doesn't look like an address, or it's already listed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Always ask")
            } footer: {
                Text("Mail from these addresses always stops for you to choose a kid. Add the address you forward things from yourself — a photo or a PDF could be for either child, and nothing in the message says which.")
            }

            if !unroutedExemptions.isEmpty {
                Section("Always ask (no mail yet)") {
                    ForEach(unroutedExemptions, id: \.self) { address in
                        Text(address).font(.callout)
                    }
                    .onDelete { offsets in
                        for index in offsets { AlwaysAskSenders.remove(unroutedExemptions[index]) }
                    }
                }
            }

            Section {
                if routes.isEmpty {
                    Text("Nothing learned yet. Assigning an email to a kid teaches the app that this sender means that kid.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(routes) { route in
                        SenderRow(route: route, kidName: kidsByID[route.kidID]?.name)
                    }
                    .onDelete(perform: deleteRoutes)
                }
            } header: {
                Text("Learned senders")
            } footer: {
                Text("Learned from the last time you assigned an email from each address. Deleting one makes the next email from that sender ask again.")
            }
        }
        .navigationTitle("Senders")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func addExemption() {
        addFailed = !AlwaysAskSenders.add(newAddress)
        if !addFailed { newAddress = "" }
    }

    private func deleteRoutes(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(routes[index]) }
        try? modelContext.save()
    }
}

/// One learned sender, with the switch that stops the app guessing about it.
private struct SenderRow: View {
    let route: SenderRoute
    let kidName: String?

    /// Mirrors the stored list rather than owning the truth, because the list
    /// lives in defaults and this row is redrawn from it.
    @State private var alwaysAsk: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(route.sender)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(kidName ?? "Unknown kid")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Always ask which kid", isOn: $alwaysAsk)
                .font(.caption)
        }
        .onAppear { alwaysAsk = AlwaysAskSenders.contains(route.sender) }
        .onChange(of: alwaysAsk) { _, isOn in
            AlwaysAskSenders.setAlwaysAsk(isOn, for: route.sender)
        }
    }
}
