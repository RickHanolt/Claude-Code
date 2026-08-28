import SwiftUI
import SwiftData

/// Every email you've forwarded into SchoolSync, in full — independent of
/// whether any calendar events were detected/confirmed for it. A browsable
/// backstop for anything the date-detection heuristic missed or you just
/// want to re-read later.
struct EmailsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ForwardedEmailRecord.sharedDate, order: .reverse) private var emails: [ForwardedEmailRecord]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]
    @Query(sort: \SchoolRecord.name) private var schools: [SchoolRecord]

    private var kidsByID: [UUID: KidRecord] { Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) }) }
    private var schoolsByID: [UUID: SchoolRecord] { Dictionary(uniqueKeysWithValues: schools.map { ($0.id, $0) }) }

    var body: some View {
        Group {
            Group {
                if emails.isEmpty {
                    ContentUnavailableView(
                        "No forwarded emails yet",
                        systemImage: "envelope",
                        description: Text("Share a school email into SchoolSync from Mail to see it here.")
                    )
                } else {
                    List {
                        ForEach(emails) { email in
                            NavigationLink {
                                EmailDetailView(email: email, kid: kidsByID[email.kidID], school: schoolsByID[email.schoolID])
                            } label: {
                                emailRow(email)
                            }
                        }
                        .onDelete(perform: deleteEmails)
                    }
                }
            }
            .navigationTitle("Emails")
        }
    }

    private func emailRow(_ email: ForwardedEmailRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(email.subject).font(.body).lineLimit(1)
            Text(subtitle(for: email)).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func subtitle(for email: ForwardedEmailRecord) -> String {
        var parts: [String] = []
        if let kid = kidsByID[email.kidID] { parts.append(kid.name) }
        if let school = schoolsByID[email.schoolID] { parts.append(school.name) }
        parts.append(email.sharedDate.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private func deleteEmails(at offsets: IndexSet) {
        for index in offsets { modelContext.delete(emails[index]) }
        try? modelContext.save()
    }
}

private struct EmailDetailView: View {
    let email: ForwardedEmailRecord
    let kid: KidRecord?
    let school: SchoolRecord?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(email.subject).font(.title2).bold()

                HStack(spacing: 6) {
                    if let kid { Text(kid.name) }
                    if let school { Text("· \(school.name)") }
                    Text("· \(email.sharedDate.formatted(date: .abbreviated, time: .shortened))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()

                Text(email.bodyText)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.inline)
    }
}
