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

    /// Idempotent on the email id. The same email is seen on every sync until
    /// it's consumed, and a warning that multiplied would train you to ignore
    /// the whole mechanism.
    static func record(_ notice: AttentionNotice) {
        var current = all
        guard !current.contains(where: { $0.id == notice.id }) else { return }
        current.append(notice)
        write(current)
    }

    static func dismiss(id: String) {
        write(all.filter { $0.id != id })
    }

    static func dismissAll() {
        write([])
    }

    private static func write(_ notices: [AttentionNotice]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notices) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
