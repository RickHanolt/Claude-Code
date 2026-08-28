import Foundation
import SwiftData

/// What a kid needs on an ordinary day, and the exceptions that displace it.
///
/// This is the shape the whole Morning Mode idea rests on, and it came from the
/// user rather than from me: state each kid's baseline explicitly, then let the
/// model's job shrink to spotting *deviations*. Jonah wears a uniform, so the
/// only interesting thing an email can say about clothing is "jeans day" or
/// "spirit week". Teddy eats both meals at school, so the only interesting
/// thing is a closure or a field trip.
///
/// Asking "what should this kid wear" every morning is an open question with no
/// reliable answer. Asking "does anything override the uniform on this date" is
/// a lookup that is right by default and wrong only when something was missed —
/// and a missed exception degrades to the normal day, which is the safe way to
/// be wrong.

/// The fields Morning Mode shows per kid. Stored as a string rather than an
/// integer so a value added later can't renumber the existing rows.
enum DayField: String, Codable, CaseIterable, Sendable {
    case breakfast
    case lunch
    case clothing
    case reminder

    var label: String {
        switch self {
        case .breakfast: "Breakfast"
        case .lunch: "Lunch"
        case .clothing: "Clothing"
        case .reminder: "Reminders"
        }
    }
}

/// Where an exception came from, so the UI can say why it's overriding the
/// baseline and the user can tell a guess from a fact.
enum DayExceptionSource: String, Codable, Sendable {
    /// Pulled out of a school email by extraction.
    case email
    /// A published menu or schedule (MealViewer, Boonli, the semester PDF).
    case schedule
    /// Typed in by the user, and therefore never overwritten by a sync.
    case manual

    var isTrustworthy: Bool { self == .manual || self == .schedule }
}

/// One kid's ordinary day.
///
/// Every field carries a plain-language default because that is what actually
/// gets displayed. There is no clever encoding of "packs lunch" — the string
/// the parent wants to read in the morning is the string that gets stored.
@Model
final class KidDayDefaults {
    @Attribute(.unique) var kidID: UUID

    var breakfast: String
    var lunch: String
    var clothing: String

    /// Anything true every day that isn't covered above — "water bottle",
    /// "library book on Thursdays". Shown under reminders beneath any
    /// date-specific ones.
    var standingReminder: String?

    init(
        kidID: UUID,
        breakfast: String = "",
        lunch: String = "",
        clothing: String = "",
        standingReminder: String? = nil
    ) {
        self.kidID = kidID
        self.breakfast = breakfast
        self.lunch = lunch
        self.clothing = clothing
        self.standingReminder = standingReminder
    }

    func value(for field: DayField) -> String {
        switch field {
        case .breakfast: breakfast
        case .lunch: lunch
        case .clothing: clothing
        case .reminder: standingReminder ?? ""
        }
    }

    func setValue(_ value: String, for field: DayField) {
        switch field {
        case .breakfast: breakfast = value
        case .lunch: lunch = value
        case .clothing: clothing = value
        case .reminder: standingReminder = value.isEmpty ? nil : value
        }
    }
}

/// A single day where the baseline doesn't hold.
///
/// Keyed by day rather than by an exact instant: "jeans day" applies to a
/// date, not to a moment, and a time here would only create a class of
/// near-miss bugs when two sources describe the same day slightly differently.
@Model
final class DayException {
    @Attribute(.unique) var id: String

    var kidID: UUID
    /// Start of day in the household's timezone, so lookups are an equality
    /// check rather than a range scan.
    var day: Date
    var fieldRaw: String
    var value: String
    var sourceRaw: String

    /// Where this came from in prose — "SMA newsletter, Aug 27" — so the app
    /// can show why it's overriding the default instead of asserting it.
    var provenance: String?

    var field: DayField {
        get { DayField(rawValue: fieldRaw) ?? .reminder }
        set { fieldRaw = newValue.rawValue }
    }

    var source: DayExceptionSource {
        get { DayExceptionSource(rawValue: sourceRaw) ?? .email }
        set { sourceRaw = newValue.rawValue }
    }

    /// Stable across re-syncs of the same source, so re-reading a menu updates
    /// the row instead of stacking another copy of it — the same upsert-not-
    /// duplicate property `SchoolEventRecord.externalID` provides.
    static func identity(kidID: UUID, day: Date, field: DayField, source: DayExceptionSource) -> String {
        "\(kidID.uuidString):\(Int(day.timeIntervalSince1970)):\(field.rawValue):\(source.rawValue)"
    }

    init(
        kidID: UUID,
        day: Date,
        field: DayField,
        value: String,
        source: DayExceptionSource,
        provenance: String? = nil
    ) {
        self.id = DayException.identity(kidID: kidID, day: day, field: field, source: source)
        self.kidID = kidID
        self.day = day
        self.fieldRaw = field.rawValue
        self.value = value
        self.sourceRaw = source.rawValue
        self.provenance = provenance
    }
}
