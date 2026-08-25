import Foundation
import EventKit
import SwiftData

enum CalendarSyncError: Error {
    case accessDenied
    case noWritableSource
}

/// Writes merged `SchoolEventRecord`s into a dedicated EventKit calendar per
/// kid ("Emma — School"), so they show up in the Calendar app / any calendar
/// widget the user already has, alongside everything else. De-duplication
/// against manual edits or re-syncs works by tagging each EKEvent's notes
/// with a hidden `[SchoolSyncID:...]` marker and searching for it, since
/// EventKit has no first-class "external identifier" field for third-party
/// calendars.
@MainActor
final class CalendarSyncService {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool {
        if #available(iOS 17.0, *) {
            return try await store.requestFullAccessToEvents()
        } else {
            return try await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: .event) { granted, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: granted) }
                }
            }
        }
    }

    /// Finds or creates the dedicated calendar for a kid.
    func calendar(for kid: KidRecord) throws -> EKCalendar {
        let title = "\(kid.name) — School"
        if let existing = store.calendars(for: .event).first(where: { $0.title == title }) {
            return existing
        }

        guard let source = store.defaultCalendarForNewEvents?.source
            ?? store.sources.first(where: { $0.sourceType == .local })
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
        else {
            throw CalendarSyncError.noWritableSource
        }

        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        calendar.cgColor = UIColorHex(kid.colorHex).cgColor
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    /// Upserts every event belonging to `kid` into that kid's dedicated
    /// calendar and records the resulting `EKEvent.eventIdentifier` back onto
    /// the SwiftData record.
    func sync(events: [SchoolEventRecord], kid: KidRecord, modelContext: ModelContext) throws {
        let calendar = try self.calendar(for: kid)

        for record in events where record.kidID == kid.id {
            let tag = "[SchoolSyncID:\(record.externalID)]"
            let event = findExistingEvent(tag: tag, calendar: calendar, near: record.startDate) ?? EKEvent(eventStore: store)

            event.calendar = calendar
            event.title = record.title
            event.startDate = record.startDate
            event.endDate = record.endDate ?? record.startDate.addingTimeInterval(3600)
            event.isAllDay = record.isAllDay
            event.location = record.location

            var notes = record.notes ?? ""
            if !notes.isEmpty { notes += "\n\n" }
            notes += tag
            event.notes = notes

            try store.save(event, span: .thisEvent)
            record.calendarSyncIdentifier = event.eventIdentifier
        }

        try modelContext.save()
    }

    private func findExistingEvent(tag: String, calendar: EKCalendar, near date: Date) -> EKEvent? {
        let window: TimeInterval = 60 * 60 * 24 * 400
        let start = date.addingTimeInterval(-window)
        let end = date.addingTimeInterval(window)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).first { $0.notes?.contains(tag) == true }
    }
}

#if canImport(UIKit)
import UIKit
private func UIColorHex(_ hex: String) -> UIColor {
    var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    cleaned.removeAll { $0 == "#" }
    guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return .systemBlue }
    let r = CGFloat((value >> 16) & 0xFF) / 255
    let g = CGFloat((value >> 8) & 0xFF) / 255
    let b = CGFloat(value & 0xFF) / 255
    return UIColor(red: r, green: g, blue: b, alpha: 1)
}
#endif
