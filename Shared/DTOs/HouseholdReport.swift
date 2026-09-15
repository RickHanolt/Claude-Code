import Foundation

/// A viewer saying something looks wrong.
///
/// Encrypted with the household key like everything else that leaves a phone,
/// so the backend stores it without being able to read it — which matters more
/// here than for the snapshot, because this is free text written by a person
/// who may well name a child and a school in the same sentence.
///
/// Carries context the reporter didn't have to type. "Teddy, Thursday" attached
/// automatically is the difference between a report you can act on and a text
/// message saying "something's wrong with the app".
struct HouseholdReport: Codable, Sendable {
    var message: String
    var kidID: UUID?
    var kidName: String?
    var day: Date?
    var createdAt: Date

    /// Which snapshot the reporter was looking at. Recorded because half of
    /// "this is wrong" turns out to be "this is old", and those need different
    /// answers.
    var snapshotVersion: Int?
}
