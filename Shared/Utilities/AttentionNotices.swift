import Foundation

/// An email that arrived carrying something the app couldn't read.
///
/// Usually a picture: school newsletters put their monthly calendar on the
/// mailing platform's CDN and reference it, so the bytes never travel in the
/// message. When that picture can't be fetched, the dates on it are simply
/// absent — and absence is the hardest thing in this app to notice. A September
/// calendar cost us "Pizza/Jean Day" and nothing anywhere said so.
struct AttentionNotice: Codable, Identifiable, Equatable, Sendable {
    /// The forwarded email's id, so re-syncing the same email doesn't stack up
    /// the same warning every fifteen minutes.
    var id: String
    var subject: String
    var note: String
    var receivedAt: Date
}

/// Things the app wants to tell you about, that aren't about today.
///
/// Kept separate from the pending-review queue for one reason: an email whose
/// sender is known gets filed automatically and leaves that queue immediately,
/// taking its explanation with it. That is precisely the email most likely to
/// have lost a picture — so the warning has to outlive the review.
///
/// Dismissal is explicit and per-notice. Clearing these on sync would mean the
/// warning disappears on its own between the moment it's raised and the moment
/// anyone opens the app.
enum AttentionNotices {
    static let storageKey = "attention.notices"

    /// Ids the user has explicitly finished with.
    ///
    /// Needed because dismissal and re-recording pull in opposite directions.
    /// `record` runs on every sync for as long as the email sits unreviewed in
    /// the backend queue, and an email from an unrecognised sender sits there
    /// until somebody reviews it — which may be never. Without this, the
    /// dismissal worked and the next sync undid it, so the button looked
    /// broken while doing exactly what it was asked.
    ///
    /// Absence from the list is not evidence of anything. "I haven't seen this"
    /// and "I've seen it and I'm done" look identical from there, and only one
    /// of them wants a warning raised again.
    static let dismissedKey = "attention.dismissed"

    /// Old ones age out rather than accumulating forever. A calendar picture
    /// missed two months ago is history, not a task.
    private static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    private static var defaults: UserDefaults { AppGroup.sharedDefaults ?? .standard }

    static var all: [AttentionNotice] {
        decode(defaults.data(forKey: storageKey) ?? Data())
    }

    static func decode(_ data: Data) -> [AttentionNotice] {
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let stored = (try? decoder.decode([AttentionNotice].self, from: data)) ?? []
        let cutoff = Date.now.addingTimeInterval(-lifetime)
        return stored
            .filter { $0.receivedAt > cutoff }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    /// Idempotent on the email id, and permanent once dismissed.
    ///
    /// The same email is returned by the backend on every sync until it is
    /// reviewed and saved, so this runs repeatedly for one warning. Duplicating
    /// would train you to ignore the mechanism; resurrecting a dismissed one
    /// looks like the dismiss button is broken.
    static func record(_ notice: AttentionNotice) {
        guard shouldRecord(notice.id, existing: all.map(\.id), dismissed: dismissedIDs) else { return }
        write(all + [notice])
    }

    /// The whole decision, as a function of values.
    ///
    /// Pulled out so the rule can be asserted without a defaults suite — the
    /// storage around it is four lines of JSON and was never the part that was
    /// wrong.
    static func shouldRecord(_ id: String, existing: [String], dismissed: [String]) -> Bool {
        !existing.contains(id) && !dismissed.contains(id)
    }

    static func dismiss(id: String) {
        rememberDismissed([id])
        write(all.filter { $0.id != id })
    }

    static func dismissAll() {
        rememberDismissed(all.map(\.id))
        write([])
    }

    // MARK: - Dismissals

    /// An id the user finished with, and when — so these age out on the same
    /// clock as the notices rather than accumulating for the life of the app.
    private struct Dismissal: Codable {
        var id: String
        var at: Date
    }

    static var dismissedIDs: [String] { storedDismissals().map(\.id) }

    private static func storedDismissals() -> [Dismissal] {
        guard let data = defaults.data(forKey: dismissedKey), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let cutoff = Date.now.addingTimeInterval(-lifetime)
        return ((try? decoder.decode([Dismissal].self, from: data)) ?? [])
            .filter { $0.at > cutoff }
    }

    private static func rememberDismissed(_ ids: [String]) {
        var current = storedDismissals()
        let known = Set(current.map(\.id))
        current.append(contentsOf: ids.filter { !known.contains($0) }.map { Dismissal(id: $0, at: .now) })

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(current) else { return }
        defaults.set(data, forKey: dismissedKey)
    }

    private static func write(_ notices: [AttentionNotice]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notices) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
