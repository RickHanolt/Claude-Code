import SwiftUI
import SwiftData

/// The owner's side of viewer mode: invite a phone, see what's joined, cut one
/// off.
///
/// Everything here is deliberately reversible. Handing someone a code is the
/// easiest thing in the app to do by accident or regret, so the list below is
/// the whole point of the screen — an invite you can't see and can't undo is
/// worse than no sharing at all.
struct ViewersListView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var viewers: [ViewerClient.Viewer] = []
    @State private var isLoading = false
    @State private var isInviting = false
    @State private var error: String?

    @State private var invite: ViewerInvite?
    @State private var pendingRevoke: ViewerClient.Viewer?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await createInvite() }
                } label: {
                    if isInviting {
                        ProgressView()
                    } else {
                        Label("Invite a phone", systemImage: "qrcode")
                    }
                }
                .disabled(isInviting || ViewerClient.owner() == nil)
            } footer: {
                if ViewerClient.owner() == nil {
                    Text("Sharing needs the auto-forward backend set up first — it's what holds the update the other phone reads.")
                } else {
                    Text("Creates a code that works once, and only for the next day. The other phone scans it and from then on shows this schedule, read-only.")
                }
            }

            Section {
                if isLoading && viewers.isEmpty {
                    HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) }
                } else if viewers.isEmpty {
                    Text("Nobody else is following this schedule yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewers) { viewer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(displayName(viewer))
                            Text(lastSeen(viewer))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        // Swiped, not tapped. A destructive button living
                        // inside a row is how a whole screen of day changes
                        // got deleted one afternoon; a row that does nothing
                        // when you touch it can't repeat that.
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingRevoke = viewer
                            } label: {
                                Label("Remove", systemImage: "person.badge.minus")
                            }
                        }
                    }
                }
            } header: {
                Text("Following")
            } footer: {
                Text("Swipe a phone to remove it. It stops receiving updates immediately and keeps whatever it last downloaded.")
            }

            if let error {
                Section {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $invite) { invite in
            InviteSheet(invite: invite)
        }
        .confirmationDialog(
            "Remove this phone?",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible,
            presenting: pendingRevoke
        ) { viewer in
            Button("Remove \(displayName(viewer))", role: .destructive) {
                Task { await revoke(viewer) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They'll stop getting updates. You can always invite them again with a new code.")
        }
    }

    /// A phone with no name is still a phone someone is holding, so it gets
    /// a noun rather than an empty row.
    private func displayName(_ viewer: ViewerClient.Viewer) -> String {
        guard let label = viewer.label, !label.isEmpty else { return "A phone" }
        return label
    }

    private func lastSeen(_ viewer: ViewerClient.Viewer) -> String {
        guard let seen = viewer.lastSeenAt else {
            return "Joined \(viewer.createdAt.formatted(.relative(presentation: .named))) — hasn't opened the app yet"
        }
        return "Last checked \(seen.formatted(.relative(presentation: .named)))"
    }

    private func load() async {
        guard let client = ViewerClient.owner() else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            viewers = try await client.listViewers()
            // Corrects itself from the server rather than trusting the local
            // flag: publishing for nobody wastes an upload, and not publishing
            // for somebody is a grandparent reading last week's schedule.
            ViewerSettings.hasViewers = !viewers.isEmpty
            error = nil
        } catch {
            self.error = "Couldn't load the list — \(error.localizedDescription)"
        }
    }

    private func createInvite() async {
        guard let client = ViewerClient.owner(), let baseURL = IngestSettings.baseURL else { return }
        isInviting = true
        defer { isInviting = false }

        do {
            let created = try await client.createInvite()
            let key = ViewerSettings.householdKeyCreatingIfNeeded()

            // Set before publishing, because publishing is what reads it.
            ViewerSettings.hasViewers = true

            // Publish now rather than waiting for the next sync. Otherwise the
            // first thing the person who just scanned sees is an empty app,
            // which reads as "this is broken", not "check back later".
            await SnapshotService(modelContext: modelContext)
                .publishIfNeeded(hasViewers: true)

            invite = ViewerInvite(
                url: baseURL.absoluteString,
                code: created.code,
                key: HouseholdCrypto.encode(key)
            )
            error = nil
        } catch {
            self.error = "Couldn't create a code — \(error.localizedDescription)"
        }
    }

    private func revoke(_ viewer: ViewerClient.Viewer) async {
        guard let client = ViewerClient.owner() else { return }
        pendingRevoke = nil

        do {
            try await client.revokeViewer(id: viewer.id)
            await load()
        } catch {
            self.error = "Couldn't remove that phone — \(error.localizedDescription)"
        }
    }
}

/// The code itself, on screen and big.
///
/// Shown once and not stored: it's single-use, so a copy kept around would only
/// ever be a copy that no longer works. If the sheet is dismissed too early,
/// making another one costs a tap.
private struct InviteSheet: View {
    let invite: ViewerInvite
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text("On the other phone, install SchoolSync, tap **Join with a code**, and point it at this.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    if let encoded = invite.encoded {
                        QRCodeView(contents: encoded)

                        // Texting it is the fallback when two phones can't be
                        // in the same room. Worth knowing: whoever opens that
                        // message first can join. It's good for one phone and
                        // one day, and removing a phone is one swipe.
                        ShareLink(item: encoded) {
                            Label("Send the code instead", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Text("Couldn't build the code. Try again.")
                            .foregroundStyle(.red)
                    }

                    Text("Works once, and only for the next 24 hours.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Invite a phone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// So the sheet can be driven by `.sheet(item:)`, which guarantees the invite
/// exists when the sheet builds — unlike a boolean plus a separate optional,
/// where the two can disagree for a frame.
extension ViewerInvite: Identifiable {
    var id: String { code }
}
