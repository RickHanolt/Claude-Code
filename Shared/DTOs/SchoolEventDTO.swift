import Foundation

/// Common shape produced by every ingestion path (ICS, scrape, email) before
/// it gets upserted into the SwiftData store by `EventStore`.
struct SchoolEventDTO: Identifiable, Codable, Hashable, Sendable {
    /// Stable external identifier used for de-duplication across sync runs.
    /// - ICS: the feed's own UID.
    /// - Scrape: a hash of school + title + start date (see `String.stableID`).
    /// - Email: a hash of school + title + start date, assigned once the user
    ///   confirms the candidate event in the share extension.
    var id: String

    var title: String
    var startDate: Date
    var endDate: Date?
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var kidID: UUID
    var schoolID: UUID
    var source: EventSourceType
}

/// A date-detector hit inside forwarded email text, before the user has
/// picked which kid/school it belongs to. See `EmailParserService`.
struct ParsedCandidateEvent: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var startDate: Date
    var endDate: Date?
    var notes: String?
}
