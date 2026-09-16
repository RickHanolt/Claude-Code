import Foundation
import SwiftData

/// An activity one kid doesn't do.
///
/// Every other kind of filtering this app could apply is an inference about
/// what a document meant. This one isn't an inference at all: a parent said
/// "he doesn't run cross country", and no email will ever contain that fact.
/// Which is why it's a stored decision rather than a rule — there is nothing to
/// get right, only something to remember.
///
/// It exists because deleting was not enough. A recurring activity is stored as
/// one row per session, so clearing a season is dozens of swipes, and the next
/// newsletter brings the next dozen. A tombstone answers for one date; this
/// answers for the activity.
@Model
final class MutedActivity {
    @Attribute(.unique) var id: String

    var kidID: UUID

    /// As the user last saw it, for the list where they undo this. The match
    /// key is unreadable by design, and a screen that offered to un-mute
    /// "cross country practice" when the calendar says "Cross Country Practice"
    /// would be asking them to trust a transformation they can't see.
    var title: String

    var matchKey: String
    var mutedAt: Date

    init(kidID: UUID, title: String, mutedAt: Date = .now) {
        self.id = MutedActivity.identity(kidID: kidID, title: title)
        self.kidID = kidID
        self.title = title
        self.matchKey = MutedActivity.matchKey(for: title)
        self.mutedAt = mutedAt
    }

    static func identity(kidID: UUID, title: String) -> String {
        "\(kidID.uuidString):\(matchKey(for: title))"
    }

    /// Case and punctuation folded away, nothing else.
    ///
    /// Exact on the folded string, never fuzzy, and that is the whole safety
    /// argument. Fuzzy matching here would mean a parent silencing "Cross
    /// Country Practice" and quietly losing "Cross Country Meet" — a race they
    /// may well be driving to. What this hides has to be exactly what they
    /// pointed at, so they can predict it without being told.
    static func matchKey(for title: String) -> String {
        let folded = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : " "
        }
        return String(folded).split(separator: " ").joined(separator: " ")
    }
}

/// The question `EventStore` and the calendar ask before showing an activity.
///
/// A free function over values rather than a fetch, so the rule can be asserted
/// without a store — and so the one place that decides whether a parent ever
/// sees an event is a place that can be tested.
enum ActivityMute {
    static func isMuted(title: String, kidID: UUID, in mutes: [MutedActivity]) -> Bool {
        let key = MutedActivity.matchKey(for: title)
        return mutes.contains { $0.kidID == kidID && $0.matchKey == key }
    }
}
