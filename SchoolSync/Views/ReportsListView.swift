import SwiftUI

/// What the viewers have reported, on the owner's phone.
///
/// Reports are decrypted here and nowhere else — the backend holds ciphertext
/// and the list below is the first point at which anyone can read them.
///
/// Acknowledging is explicit rather than automatic-on-view. A report read on
/// the way into a meeting and forgotten is exactly the one that needed to stay
/// in the list.
struct ReportsListView: View {
    @State private var reports: [DecryptedReport] = []
    @State private var undecryptable = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var pendingAck: DecryptedReport?

    struct DecryptedReport: Identifiable {
        let id: String
        let report: HouseholdReport
        let viewerLabel: String?
        let receivedAt: Date
    }

    var body: some View {
        Form {
            if isLoading && reports.isEmpty {
                Section { HStack { ProgressView(); Text("Loading…").foregroundStyle(.secondary) } }
            } else if reports.isEmpty {
                Section {
                    Text("Nothing reported.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(reports) { item in
                Section {
                    Text(item.report.message)

                    if let context = contextLine(item) {
                        Text(context).font(.caption).foregroundStyle(.secondary)
                    }

                    if let staleness = stalenessLine(item) {
                        // Worth its own line and its own colour. "This is
                        // wrong" and "this is old" look identical from the
                        // reporter's side and need completely different fixes.
                        Text(staleness).font(.caption).foregroundStyle(Color.orange)
                    }

                    Button("Mark as handled") { pendingAck = item }
                } header: {
                    Text("\(item.viewerLabel ?? "A phone") · \(item.report.createdAt.formatted(.relative(presentation: .named)))")
                }
            }

            if undecryptable > 0 {
                Section {
                    Text("\(undecryptable) report\(undecryptable == 1 ? "" : "s") couldn't be read — sent from a phone holding a different code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Section { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Reports")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            "Mark as handled?",
            isPresented: Binding(get: { pendingAck != nil }, set: { if !$0 { pendingAck = nil } }),
            titleVisibility: .visible
        ) {
            Button("Mark as handled") {
                if let pendingAck { Task { await acknowledge(pendingAck) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from this list. Whoever sent it isn't notified either way.")
        }
    }

    private func contextLine(_ item: DecryptedReport) -> String? {
        var parts: [String] = []
        if let name = item.report.kidName { parts.append(name) }
        if let day = item.report.day {
            parts.append(day.formatted(.dateTime.weekday(.wide).month().day()))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// How far behind the reporter's phone was when they wrote it.
    private func stalenessLine(_ item: DecryptedReport) -> String? {
        guard let theirs = item.report.snapshotVersion,
              let published = ViewerSettings.publishedVersion,
              published > theirs
        else { return nil }

        let behind = published - theirs
        return "They were \(behind) update\(behind == 1 ? "" : "s") behind when they sent this."
    }

    private func load() async {
        guard let client = ViewerClient.owner(), let key = ViewerSettings.householdKey else {
            error = "Sharing isn't set up on this phone."
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let stored = try await client.listReports()
            var decrypted: [DecryptedReport] = []
            var failed = 0

            for row in stored {
                // One unreadable report must not hide the rest. A viewer left
                // holding an old key is a real situation, and the readable
                // reports around it are still worth acting on.
                guard let report = try? HouseholdCrypto.open(HouseholdReport.self, from: row.payload, with: key) else {
                    failed += 1
                    continue
                }
                decrypted.append(
                    DecryptedReport(
                        id: row.id,
                        report: report,
                        viewerLabel: row.viewerLabel,
                        receivedAt: row.createdAt
                    )
                )
            }

            reports = decrypted.sorted { $0.report.createdAt > $1.report.createdAt }
            undecryptable = failed
            error = nil
        } catch {
            self.error = "Couldn't load reports — \(error.localizedDescription)"
        }
    }

    private func acknowledge(_ item: DecryptedReport) async {
        pendingAck = nil
        guard let client = ViewerClient.owner() else { return }

        do {
            try await client.acknowledgeReports(ids: [item.id])
            reports.removeAll { $0.id == item.id }
        } catch {
            self.error = "Couldn't mark that handled — \(error.localizedDescription)"
        }
    }
}
