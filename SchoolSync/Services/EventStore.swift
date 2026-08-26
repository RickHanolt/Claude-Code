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
    /// `externalID`), so re-running a sync doesn't duplicate anything.
    @discardableResult
    func upsert(_ dtos: [SchoolEventDTO]) throws -> Int {
        var changed = 0
        for dto in dtos {
            let externalID = dto.id
            let descriptor = FetchDescriptor<SchoolEventRecord>(
                predicate: #Predicate { $0.externalID == externalID }
            )
            if let existing = try modelContext.fetch(descriptor).first {
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
            let externalID = dto.id
            let descriptor = FetchDescriptor<ForwardedEmailRecord>(
                predicate: #Predicate { $0.externalID == externalID }
            )
            if try modelContext.fetch(descriptor).first == nil {
                modelContext.insert(ForwardedEmailRecord(dto: dto))
            }
        }
        try modelContext.save()
        try SharedEmailQueue.clear()
        return pending.count
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

    func fetchEvents(for kidID: UUID) throws -> [SchoolEventRecord] {
        let descriptor = FetchDescriptor<SchoolEventRecord>(
            predicate: #Predicate { $0.kidID == kidID },
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
