import SwiftUI

/// What the app couldn't read, and what to do about it.
///
/// One screen rather than a banner with a count, because the useful thing isn't
/// "something went wrong" — it's *which email*, so you can open that newsletter
/// and forward the picture yourself.
struct AttentionNoticesView: View {
    @AppStorage(AttentionNotices.storageKey, store: AppGroup.sharedDefaults)
    private var stored = Data()

    private var notices: [AttentionNotice] { AttentionNotices.decode(stored) }

    var body: some View {
        Form {
            if notices.isEmpty {
                Section {
                    Text("Nothing needs a look.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(notices) { notice in
                Section {
                    Text(notice.note)
                        .font(.callout)

                    Button("Done — I've handled it") {
                        AttentionNotices.dismiss(id: notice.id)
                    }
                } header: {
                    Text(notice.subject)
                } footer: {
                    Text("Arrived \(notice.receivedAt.formatted(.relative(presentation: .named))). Open that email and forward the picture on its own to add whatever it holds.")
                }
            }

            if notices.count > 1 {
                Section {
                    Button("Dismiss all", role: .destructive) {
                        AttentionNotices.dismissAll()
                    }
                }
            }
        }
        .navigationTitle("Needs a look")
        .navigationBarTitleDisplayMode(.inline)
    }
}
