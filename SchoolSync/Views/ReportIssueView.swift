import SwiftUI
import SwiftData

/// A viewer telling the owner something looks wrong.
///
/// The one thing a read-only phone can send. Kept to a single screen with one
/// text box and two optional taps, because the person using it is most likely
/// a grandparent who is already unsure whether the app is wrong or they are.
struct ReportIssueView: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]

    @State private var message = ""
    @State private var kidID: UUID?
    @State private var day = Date.now
    @State private var includeDay = true
    @State private var isSending = false
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("What looks wrong?", text: $message, axis: .vertical)
                    .lineLimit(4...10)
            } footer: {
                Text("Plain words are fine — \"Teddy's lunch says hot lunch but it's a packed lunch day\" is exactly right.")
            }

            Section("Which kid") {
                Picker("Kid", selection: $kidID) {
                    Text("Not about one kid").tag(UUID?.none)
                    ForEach(kids) { kid in
                        Text(kid.name).tag(UUID?.some(kid.id))
                    }
                }
            }

            Section {
                Toggle("About a particular day", isOn: $includeDay)
                if includeDay {
                    DatePicker("Day", selection: $day, displayedComponents: .date)
                }
            }

            Section {
                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        ProgressView()
                    } else {
                        Text("Send")
                    }
                }
                .disabled(isSending || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } footer: {
                if sent {
                    Text("Sent. They'll see it the next time they open the app.")
                        .foregroundStyle(.green)
                } else if let error {
                    Text(error).foregroundStyle(.red)
                } else {
                    // Said plainly rather than implied. Someone who thinks this
                    // pages a phone at 6am will word it very differently from
                    // someone who knows it's a note.
                    Text("This is a note, not a message — it arrives when they next open their app. For anything urgent, call or text.")
                }
            }
        }
        .navigationTitle("Something looks wrong")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func send() async {
        guard let client = ViewerClient.viewer(), let key = ViewerSettings.householdKey else {
            error = "This phone isn't set up to send reports."
            return
        }

        isSending = true
        defer { isSending = false }

        let report = HouseholdReport(
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            kidID: kidID,
            // The name travels alongside the id: the owner reads this, and an
            // id that no longer resolves would turn a useful report into a
            // riddle.
            kidName: kids.first { $0.id == kidID }?.name,
            day: includeDay ? Calendar.current.startOfDay(for: day) : nil,
            createdAt: .now,
            snapshotVersion: ViewerSettings.snapshotVersion,
            contentVersion: ViewerSettings.receivedContentVersion
        )

        do {
            let payload = try HouseholdCrypto.seal(report, with: key)
            try await client.sendReport(payload: payload, snapshotVersion: ViewerSettings.snapshotVersion)
            sent = true
            error = nil
            message = ""
        } catch {
            self.error = "Couldn't send — \(error.localizedDescription)"
        }
    }
}
