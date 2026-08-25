import Foundation
import SwiftData

@Model
final class SchoolEventRecord {
    /// Matches `SchoolEventDTO.id`; used to upsert instead of duplicating on
    /// every sync run.
    @Attribute(.unique) var externalID: String

    var title: String
    var startDate: Date
    var endDate: Date?
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var kidID: UUID
    var schoolID: UUID
    var sourceRaw: String

    /// Set once `CalendarSyncService` has written this event into EventKit,
    /// so subsequent syncs can find-and-update the same `EKEvent` instead of
    /// re-searching by tag every time.
    var calendarSyncIdentifier: String?

    var source: EventSourceType {
        get { EventSourceType(rawValue: sourceRaw) ?? .icsFeed }
        set { sourceRaw = newValue.rawValue }
    }

    init(dto: SchoolEventDTO) {
        self.externalID = dto.id
        self.title = dto.title
        self.startDate = dto.startDate
        self.endDate = dto.endDate
        self.isAllDay = dto.isAllDay
        self.location = dto.location
        self.notes = dto.notes
        self.kidID = dto.kidID
        self.schoolID = dto.schoolID
        self.sourceRaw = dto.source.rawValue
    }

    /// Copies the mutable fields from a freshly-fetched DTO, leaving
    /// `calendarSyncIdentifier` untouched so we keep updating the same
    /// EventKit event rather than creating a new one.
    func update(from dto: SchoolEventDTO) {
        title = dto.title
        startDate = dto.startDate
        endDate = dto.endDate
        isAllDay = dto.isAllDay
        location = dto.location
        notes = dto.notes
        kidID = dto.kidID
        schoolID = dto.schoolID
        sourceRaw = dto.source.rawValue
    }
}
