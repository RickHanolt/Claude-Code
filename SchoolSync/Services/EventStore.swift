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
            } else {
                modelContext.insert(SchoolEventRecord(dto: dto))
            }
            changed += 1
        }
        if changed > 0 {
            try modelContext.save()
        }
        return changed
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
