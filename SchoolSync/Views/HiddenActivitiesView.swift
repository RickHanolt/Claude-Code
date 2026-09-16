import SwiftUI
import SwiftData

/// Everything the app has been told not to show, and the way back.
///
/// This screen is the price of the swipe that fills it. A filter that hides
/// events forever, has no list, and no undo is indistinguishable from a bug —
/// and the parent who wonders in March why cross country never appeared has no
/// way to find out that they are the reason.
///
/// So the rule is: nothing gets hidden that isn't listed here, and nothing
/// listed here can't be undone in one tap.
struct HiddenActivitiesView: View {
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \MutedActivity.title) private var muted: [MutedActivity]
    @Query(sort: \KidRecord.name) private var kids: [KidRecord]

    private var kidsByID: [UUID: KidRecord] { Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) }) }

    var body: some View {
        List {
            if muted.isEmpty {
                // Said rather than left blank, so an empty screen reads as "you
                // haven't hidden anything" instead of "this failed to load".
                Text("Nothing is hidden. Swiping an event in Calendar and choosing \"Not for …\" will list it here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(muted) { activity in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.title)
                                Text(kidsByID[activity.kidID]?.name ?? "A kid who has since been removed")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Show") { unmute(activity) }
                                .buttonStyle(.bordered)
                        }
                    }
                } footer: {
                    // The honest caveat. Un-hiding stops the filter, it does not
                    // resurrect the rows it already tombstoned — those were
                    // deleted, and deletion is the one thing this app treats as
                    // final on purpose.
                    Text("Showing an activity again lets future sessions through. Sessions already hidden stay hidden — forward the email again to bring them back.")
                }
            }
        }
        .navigationTitle("Hidden activities")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func unmute(_ activity: MutedActivity) {
        modelContext.delete(activity)
        try? modelContext.save()
    }
}
