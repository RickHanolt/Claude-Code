import Foundation

/// Everything a read-only phone needs to draw Morning Mode and Calendar.
///
/// A projection of the owner's local store, not a second copy of it: it carries
/// what the read-only screens display and nothing about how any of it got
/// there. No forwarded emails, no sender routes, no extraction status, no
/// backend credentials. A viewer has no use for those, and the smallest
/// snapshot that does the job is also the smallest thing to leak.
///
/// Versioned from the start. A viewer running an older build will one day meet
/// a snapshot written by a newer one, and the useful behaviour then is to say
/// "your app is out of date" rather than to decode half of it and silently drop
/// whatever it didn't recognise.
struct HouseholdSnapshot: Codable, Sendable {
    static let currentFormat = 1

    var format: Int = HouseholdSnapshot.currentFormat
    var publishedAt: Date

    var kids: [Kid]
    var schools: [School]
    var defaults: [Defaults]
    var exceptions: [Exception]
    var events: [SchoolEventDTO]

    /// Counts *changes*, not publishes.
    ///
    /// The server's own version increments every time a snapshot is uploaded,
    /// and the owner's phone uploads one on every launch whether or not
    /// anything moved. That makes it useless for answering "has this changed
    /// since you looked?" — which is the only question anyone asks of it.
    ///
    /// This is bumped only when the content differs from the last publish, so a
    /// gap of one genuinely means one real change.
    var contentVersion: Int?

    /// Optional, and deliberately not a format bump: an older viewer decoding a
    /// newer snapshot ignores the key, and a newer viewer decoding an older one
    /// gets nil and simply shows no weather. Neither is a failure, so neither
    /// should be treated as one.
    var place: WeatherPlace?

    struct Kid: Codable, Sendable {
        var id: UUID
        var name: String
        var colorHex: String
    }

    /// Schools travel for their names alone — "Teddy · Pulaski" under an event.
    /// Feed URLs and scrape configs stay behind; a viewer never syncs anything.
    struct School: Codable, Sendable {
        var id: UUID
        var name: String
        var kidID: UUID
    }

    struct Defaults: Codable, Sendable {
        var kidID: UUID
        var breakfast: String
        var lunch: String
        var clothing: String
        var standingReminder: String?
    }

    struct Exception: Codable, Sendable {
        var id: String
        var kidID: UUID
        var day: Date
        var field: String
        var value: String
        var source: String
        var provenance: String?
        var isNotable: Bool
    }
}
