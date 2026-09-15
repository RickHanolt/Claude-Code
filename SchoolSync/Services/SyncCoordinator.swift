import Foundation
import SwiftData

struct SyncResult {
    var eventsIngested: Int = 0
    var errors: [String] = []

    /// Things worth saying that aren't failures — a feed that loaded but held
    /// nothing. Separate from `errors` so a legitimately empty calendar isn't
    /// printed in red, and so "nothing came back" stops being silent.
    var notes: [String] = []

    var pendingReviewCount: Int = 0
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
        _ = try? eventStore.ingestPendingForwardedEmails()

        // Auto-forward backend (optional — see INGEST_BACKEND.md): unlike
        // the share-extension queue above, these arrive with no kid/school
        // assignment yet, so we only surface a count here and let
        // PendingReviewView handle the actual review/save.
        if let client = IngestClient.configured() {
            if let pending = try? await client.fetchPending() {
                // Recorded before auto-accept, not after. An email from a known
                // sender is filed immediately and leaves the pending queue with
                // its explanation attached — and that is exactly the email most
                // likely to have lost a calendar picture on the way in.
                for email in pending.emails {
                    // The flag decides, not the note. The note is a record of
                    // everything that happened to an email's pictures, and most
                    // of that is routine housekeeping nobody needs woken for.
                    guard email.needsAttention == true,
                          let note = email.attachmentNote, !note.isEmpty
                    else { continue }
                    AttentionNotices.record(
                        AttentionNotice(
                            id: email.id,
                            subject: email.subject,
                            note: note,
                            receivedAt: email.receivedAt
                        )
                    )
                }

                result.pendingReviewCount = await autoAcceptRoutedMail(pending, client: client, into: &result)
            }
        }

        guard let schools = try? eventStore.fetchAllSchools() else {
            result.errors.append("Could not read schools from the local store.")
            return result
        }

        for school in schools {
            if let url = school.icsFeedURL {
                do {
                    let events = try await ICSFeedService().fetchEvents(from: url, kidID: school.kidID, schoolID: school.id)
                    // A valid calendar with nothing in it is legitimate — an
                    // empty month, a feed that only publishes next term. Say
                    // so anyway: the alternative is a sync that reports
                    // success while one child's calendar quietly stays empty.
                    if events.isEmpty {
                        result.notes.append("\(school.name): calendar loaded, but it lists no events.")
                    }
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

    /// Saves mail from senders whose kid is already known, and returns how many
    /// emails still need a person.
    ///
    /// The review screen exists because the backend deliberately has no idea
    /// which child an email is about — that answer only ever lived on the
    /// phone. Once a sender has been assigned even once, it isn't a question
    /// any more, and asking again every week is the app making work rather
    /// than removing it.
    ///
    /// Deliberately gated on a learned route rather than a blanket "accept
    /// everything". The first mail from any address still gets reviewed, which
    /// doubles as the safety valve: an unfamiliar sender, or a school whose
    /// address changed, can't write to a calendar unsupervised.
    private func autoAcceptRoutedMail(
        _ pending: PendingResponse,
        client: IngestClient,
        into result: inout SyncResult
    ) async -> Int {
        guard AutoAcceptSetting.isEnabled else { return pending.emails.count }

        let context = modelContext
        let routes = (try? context.fetch(FetchDescriptor<SenderRoute>())) ?? []
        let kids = (try? context.fetch(FetchDescriptor<KidRecord>())) ?? []
        let schools = (try? context.fetch(FetchDescriptor<SchoolRecord>())) ?? []
        guard !routes.isEmpty else { return pending.emails.count }

        let eventsByEmail = Dictionary(grouping: pending.events, by: \.forwardedEmailId)
        let exceptionsByEmail = Dictionary(grouping: pending.exceptions ?? [], by: \.forwardedEmailId)
        let ingestor = PendingIngestor(modelContext: context)

        var needsReview = 0

        for email in pending.emails {
            // Anything the model hasn't finished reading yet is left alone. Its
            // event list is empty for a reason that has nothing to do with the
            // email's contents, and accepting it now would file it as "nothing
            // to see" permanently.
            if email.isStillExtracting {
                needsReview += 1
                continue
            }

            guard
                let sender = SenderRoute.normalize(email.sender),
                // An address you forward things from yourself belongs to no
                // single child. Routing would file a photographed permission
                // slip to whichever kid you last picked, silently.
                !AlwaysAskSenders.contains(sender),
                let route = routes.first(where: { $0.sender == sender }),
                kids.contains(where: { $0.id == route.kidID }),
                schools.contains(where: { $0.id == route.schoolID && $0.kidID == route.kidID })
            else {
                needsReview += 1
                continue
            }

            let candidates = eventsByEmail[email.id] ?? []
            let exceptions = exceptionsByEmail[email.id] ?? []

            let saved = ingestor.save(
                email: email,
                candidates: candidates,
                // Everything, because nobody is here to uncheck anything. An
                // event that shouldn't be there is deletable on the calendar;
                // one that never arrived is invisible.
                checkedEventIDs: Set(candidates.map(\.id)),
                exceptions: exceptions,
                kidID: route.kidID,
                schoolID: route.schoolID
            )

            // Say what was added. Mail that files itself is only an improvement
            // while it's still possible to notice what it did.
            let kidName = kids.first { $0.id == route.kidID }?.name ?? "a kid"
            result.notes.append(
                "Added \(saved.eventCount) event(s) for \(kidName) from \"\(email.subject)\" automatically."
            )

            try? await client.acknowledge(
                emailIDs: [email.id],
                eventIDs: saved.eventIDs,
                exceptionIDs: saved.exceptionIDs
            )
        }

        return needsReview
    }
}
