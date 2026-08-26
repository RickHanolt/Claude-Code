import Foundation

/// The full original content of an email shared into SchoolSync, queued by
/// the share extension and picked up by the main app on its next sync —
/// independent of whether `EmailParserService` found (or the user
/// confirmed) any event candidates in it. Backs the Emails tab, which is
/// meant as a browsable record of everything you've forwarded in, not just
/// the events successfully extracted from it.
struct ForwardedEmailDTO: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var subject: String
    var bodyText: String
    var sharedDate: Date
    var kidID: UUID
    var schoolID: UUID
}
