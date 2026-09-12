import Foundation
import SwiftData

/// Upsert layer between the DTOs produced by the ingestion services and the
/// SwiftData store. Kept separate from the services themselves so
/// `ICSFeedService`/`WebScraperService`/`EmailParserService` stay pure
/// fetch-and-parse with no persistence knowledge (easier to unit test).
@MainActor
struct EventStore {
    let modelContext: ModelContext

    /// Inserts new events and updates existing ones (matched by
    /// `externalID`), so re-running a sync doesn't duplicate anything. A
    /// record the user has edited or deleted in-app is left alone — see the
    /// doc comments on `SchoolEventRecord.isUserEdited`/`isDeletedByUser` —
    /// so a source that still serves the old data can't silently undo a
    /// manual fix or resurrect something the user removed.
    @discardableResult
    func upsert(_ dtos: [SchoolEventDTO]) throws -> Int {
        var changed = 0
        for dto in dtos {
            let externalID = dto.id
            let descriptor = FetchDescriptor<SchoolEventRecord>(
                predicate: #Predicate { $0.externalID == externalID }
            )
            if let existing = try modelContext.fetch(descriptor).first {
                guard !existing.isDeletedByUser, !existing.isUserEdited else { continue }
                existing.update(from: dto)
                changed += 1
                continue
            }

            // Nothing matched by id, but another source may already have
            // described this event. A feed UID never equals a hash of an
            // email's subject, so before this the same picture day arrived
            // twice — once from the school's calendar, once from the
            // newsletter announcing it.
            if let twin = try crossSourceMatch(for: dto) {
                // A tombstone outranks everything. Deleting one copy and
                // having the other source put it back the next morning is
                // worse than never having deduplicated at all.
                guard !twin.isDeletedByUser, !twin.isUserEdited else { continue }

                // Only a more trusted source may take over the row. An email
                // arriving after the feed is dropped rather than merged: it
                // has nothing to add and would only replace a published
                // title with a sentence.
                guard EventMatching.rank(dto.source) < EventMatching.rank(twin.source) else { continue }

                // Adopt the incoming id as well as its fields. Without this
                // the row keeps the old source's id, the new source fails to
                // match it again on the very next sync, and the duplicate
                // comes straight back.
                twin.externalID = dto.id
                twin.update(from: dto)
                changed += 1
                continue
            }

            modelContext.insert(SchoolEventRecord(dto: dto))
            changed += 1
        }
        if changed > 0 {
            try modelContext.save()
        }
        return changed
    }

    /// An event on the same day that looks like the same event.
    ///
    /// One exclusion, and it's narrower than it first appears: two events from
    /// the same *feed* for the same school are left alone. A feed is a single
    /// authoritative list, and collapsing two of its entries would be this app
    /// overruling the source it's reading from — it knows whether its 3pm and
    /// 4pm sessions are distinct.
    ///
    /// Email is not that. Two forwarded documents are two documents, and they
    /// routinely describe the same closure in different words. Excluding them
    /// as "the same source" produced a day showing "No school", "No School -
    /// Professional Development", "No School - System Wide PD" and "School
    /// Improvement Day — No School" for one child, all of which the title rule
    /// would have matched had it been allowed to look.
    private func crossSourceMatch(for dto: SchoolEventDTO) throws -> SchoolEventRecord? {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: dto.startDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return nil }

        let kidID = dto.kidID

        // Narrowed in the query to one kid and one day: two children can
        // legitimately have the same event, and matching across them would
        // delete one child's copy of a shared holiday.
        let descriptor = FetchDescriptor<SchoolEventRecord>(
            predicate: #Predicate {
                $0.kidID == kidID
                    && $0.startDate >= dayStart
                    && $0.startDate < dayEnd
            }
        )

        return try modelContext.fetch(descriptor).first { record in
            guard mayMatch(record, dto) else { return false }

            return EventMatching.isSameEvent(
                titleA: record.title,
                startA: record.startDate,
                isAllDayA: record.isAllDay,
                titleB: dto.title,
                startB: dto.startDate,
                isAllDayB: dto.isAllDay,
                calendar: calendar
            )
        }
    }

    /// Whether two events are even eligible to be compared.
    ///
    /// Only one pairing is off limits: the same non-email source publishing
    /// twice for the same school. That's one list, and its author decides what
    /// counts as two entries.
    private func mayMatch(_ record: SchoolEventRecord, _ dto: SchoolEventDTO) -> Bool {
        if record.source == .emailForward || dto.source == .emailForward { return true }
        return record.source != dto.source || record.schoolID != dto.schoolID
    }

    /// Drains whatever the share extension queued in the App Group and
    /// upserts it into the real store. Call this at the start of every sync.
    @discardableResult
    func ingestPendingEmailEvents() throws -> Int {
        let pending = try SharedEventQueue.readAll()
        guard !pending.isEmpty else { return 0 }
        let count = try upsert(pending)
        try SharedEventQueue.clear()
        return count
    }

    /// Drains full forwarded emails the share extension queued — these back
    /// the Emails tab and are stored independent of whether any event
    /// candidates were confirmed for them.
    @discardableResult
    func ingestPendingForwardedEmails() throws -> Int {
        let pending = try SharedEmailQueue.readAll()
        guard !pending.isEmpty else { return 0 }
        for dto in pending {
            try insertForwardedEmailIfNeeded(dto)
        }
        try SharedEmailQueue.clear()
        return pending.count
    }

    /// Inserts a forwarded email into the store unless one with the same
    /// external id already exists (matches by `externalID`, same
    /// de-duplication key as `SchoolEventRecord`). Used both by the queue
    /// drain above and directly by `PendingReviewView` when confirming an
    /// email pulled from the Ingest backend.
    func insertForwardedEmailIfNeeded(_ dto: ForwardedEmailDTO) throws {
        let externalID = dto.id
        let descriptor = FetchDescriptor<ForwardedEmailRecord>(
            predicate: #Predicate { $0.externalID == externalID }
        )
        guard try modelContext.fetch(descriptor).first == nil else { return }
        modelContext.insert(ForwardedEmailRecord(dto: dto))
        try modelContext.save()
    }

    func fetchKids() throws -> [KidRecord] {
        try modelContext.fetch(FetchDescriptor<KidRecord>(sortBy: [SortDescriptor(\.name)]))
    }

    func fetchSchools(for kidID: UUID) throws -> [SchoolRecord] {
        let descriptor = FetchDescriptor<SchoolRecord>(
            predicate: #Predicate { $0.kidID == kidID },
            sortBy: [SortDescriptor(\.name)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetchAllSchools() throws -> [SchoolRecord] {
        try modelContext.fetch(FetchDescriptor<SchoolRecord>(sortBy: [SortDescriptor(\.name)]))
    }

    /// Excludes tombstoned events — feeds `CalendarSyncService.sync`, and
    /// including a deleted-by-user record here would resurrect it in
    /// EventKit on the very next full sync.
    func fetchEvents(for kidID: UUID) throws -> [SchoolEventRecord] {
        let descriptor = FetchDescriptor<SchoolEventRecord>(
            predicate: #Predicate { $0.kidID == kidID && !$0.isDeletedByUser },
            sortBy: [SortDescriptor(\.startDate)]
        )
        return try modelContext.fetch(descriptor)
    }

    func fetchForwardedEmails() throws -> [ForwardedEmailRecord] {
        let descriptor = FetchDescriptor<ForwardedEmailRecord>(
            sortBy: [SortDescriptor(\.sharedDate, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }
}
