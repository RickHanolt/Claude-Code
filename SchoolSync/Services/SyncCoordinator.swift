import Foundation
import SwiftData

struct SyncResult {
    var eventsIngested: Int = 0
    var errors: [String] = []
}

/// Orchestrates a full sync: drain pending email events, fetch every
/// school's ICS feed and/or scrape its page, upsert everything into
/// SwiftData, then push each kid's events into their EventKit calendar.
/// Per-school failures (a dead feed URL, a redesigned page) are collected
/// into `SyncResult.errors` rather than aborting the whole run, since one
/// school's site being down shouldn't block the other kid's calendar from
/// updating.
@MainActor
struct SyncCoordinator {
    let modelContext: ModelContext
    let calendarSyncService: CalendarSyncService

    func runFullSync() async -> SyncResult {
        let eventStore = EventStore(modelContext: modelContext)
        var result = SyncResult()

        if let ingested = try? eventStore.ingestPendingEmailEvents() {
            result.eventsIngested += ingested
        }

        guard let schools = try? eventStore.fetchAllSchools() else {
            result.errors.append("Could not read schools from the local store.")
            return result
        }

        for school in schools {
            if let url = school.icsFeedURL {
                do {
                    let events = try await ICSFeedService().fetchEvents(from: url, kidID: school.kidID, schoolID: school.id)
                    result.eventsIngested += try eventStore.upsert(events)
                } catch {
                    result.errors.append("\(school.name) (ICS feed): \(error.localizedDescription)")
                }
            }

            if let url = school.scrapeURL, let config = school.scrapeConfig {
                do {
                    let events = try await WebScraperService().scrapeEvents(from: url, config: config, kidID: school.kidID, schoolID: school.id)
                    result.eventsIngested += try eventStore.upsert(events)
                } catch {
                    result.errors.append("\(school.name) (scrape): \(error.localizedDescription)")
                }
            }
        }

        do {
            let hasAccess = try await calendarSyncService.requestAccess()
            guard hasAccess else {
                result.errors.append("Calendar access not granted — enable it in Settings to see events in the Calendar app.")
                return result
            }
        } catch {
            result.errors.append("Calendar access request failed: \(error.localizedDescription)")
            return result
        }

        guard let kids = try? eventStore.fetchKids() else { return result }
        for kid in kids {
            guard let events = try? eventStore.fetchEvents(for: kid.id) else { continue }
            do {
                try calendarSyncService.sync(events: events, kid: kid, modelContext: modelContext)
            } catch {
                result.errors.append("Calendar sync for \(kid.name): \(error.localizedDescription)")
            }
        }

        return result
    }
}
