import Foundation
import SwiftData
import CryptoKit

/// Turns the owner's store into a snapshot, and a snapshot into a viewer's
/// store.
///
/// The second half is what makes viewer mode cheap: rather than teaching every
/// screen to read from two places, a viewer's local store is *replaced* by the
/// snapshot. Morning Mode, the Calendar, the day-plan resolver and the block
/// lettering then work unchanged, because from their point of view nothing is
/// different — there are just rows, as always.
///
/// Replacing wholesale is safe here for one reason: a viewer never writes.
/// There is nothing local to preserve, so there is nothing to merge.
@MainActor
struct SnapshotService {
    let modelContext: ModelContext

    // MARK: - Publishing

    func buildSnapshot() throws -> HouseholdSnapshot {
        let kids = try modelContext.fetch(FetchDescriptor<KidRecord>())
        let schools = try modelContext.fetch(FetchDescriptor<SchoolRecord>())
        let defaults = try modelContext.fetch(FetchDescriptor<KidDayDefaults>())
        let exceptions = try modelContext.fetch(FetchDescriptor<DayException>())

        // Tombstoned events are left out rather than sent with a flag. A viewer
        // has no use for "this was deleted", and sending it would mean every
        // viewing screen needs the same filter the owner's does — a rule that
        // only has to be forgotten once.
        let events = try modelContext.fetch(
            FetchDescriptor<SchoolEventRecord>(predicate: #Predicate { !$0.isDeletedByUser })
        )

        // Sorted before mapping, every array of them. A SwiftData fetch makes
        // no promise about order, and an unstable order would make the content
        // digest below differ on every run — which would report the schedule as
        // having changed each launch, the exact false alarm this is here to
        // stop.
        return HouseholdSnapshot(
            publishedAt: .now,
            kids: kids.sorted { $0.id.uuidString < $1.id.uuidString }
                .map { .init(id: $0.id, name: $0.name, colorHex: $0.colorHex) },
            schools: schools.sorted { $0.id.uuidString < $1.id.uuidString }
                .map { .init(id: $0.id, name: $0.name, kidID: $0.kidID) },
            defaults: defaults.sorted { $0.kidID.uuidString < $1.kidID.uuidString }.map {
                .init(
                    kidID: $0.kidID,
                    breakfast: $0.breakfast,
                    lunch: $0.lunch,
                    clothing: $0.clothing,
                    standingReminder: $0.standingReminder
                )
            },
            exceptions: exceptions.sorted { $0.id < $1.id }.map {
                .init(
                    id: $0.id,
                    kidID: $0.kidID,
                    day: $0.day,
                    field: $0.fieldRaw,
                    value: $0.value,
                    source: $0.sourceRaw,
                    provenance: $0.provenance,
                    isNotable: $0.isNotable
                )
            },
            events: events.sorted { $0.externalID < $1.externalID }.map {
                SchoolEventDTO(
                    id: $0.externalID,
                    title: $0.title,
                    startDate: $0.startDate,
                    endDate: $0.endDate,
                    isAllDay: $0.isAllDay,
                    location: $0.location,
                    notes: $0.notes,
                    kidID: $0.kidID,
                    schoolID: $0.schoolID,
                    source: $0.source
                )
            },
            // Travels with the schedule so a viewing phone shows the weather
            // where the kids are, not where that phone is. It's the difference
            // between "coat" meaning something and meaning nothing.
            place: WeatherSettings.place
        )
    }

    /// Builds, encrypts and publishes. Called after a successful sync.
    ///
    /// Silent when there are no viewers to serve: a household that never
    /// invited anyone shouldn't be pushing its calendar to a server after every
    /// sync for nobody's benefit.
    func publishIfNeeded(hasViewers: Bool) async {
        guard hasViewers, let client = ViewerClient.owner() else { return }

        do {
            var snapshot = try buildSnapshot()

            // Published every time regardless, because the timestamp is a
            // heartbeat: a viewer needs to know this phone is still in touch,
            // and skipping quiet days would show them an orange "stale" line
            // through a perfectly normal week.
            //
            // What is *not* bumped every time is the content version.
            let digest = Self.digest(of: snapshot)
            if digest != ViewerSettings.contentDigest {
                ViewerSettings.publishedContentVersion += 1
                ViewerSettings.contentDigest = digest
            }
            snapshot.contentVersion = ViewerSettings.publishedContentVersion

            let payload = try HouseholdCrypto.seal(
                snapshot,
                with: ViewerSettings.householdKeyCreatingIfNeeded()
            )
            let receipt = try await client.publish(payload: payload)
            ViewerSettings.publishedVersion = receipt.version
        } catch {
            // Publishing is a side effect of syncing, not the point of it. A
            // failure here must not make the owner's own sync look broken —
            // the next sync republishes, and viewers show how stale they are.
            print("Snapshot publish failed: \(error.localizedDescription)")
        }
    }

    /// A fingerprint of what the snapshot *says*, ignoring when it was said.
    ///
    /// `publishedAt` is zeroed and `contentVersion` cleared before hashing, or
    /// every snapshot would differ from the last by definition and the count
    /// would be back to counting publishes.
    static func digest(of snapshot: HouseholdSnapshot) -> String {
        var canonical = snapshot
        canonical.publishedAt = Date(timeIntervalSince1970: 0)
        canonical.contentVersion = nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        guard let data = try? encoder.encode(canonical) else { return UUID().uuidString }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Receiving

    /// Replaces this phone's store with the snapshot's contents.
    ///
    /// Everything derived goes first, including events already written into the
    /// iOS calendar, so a stale row can't survive as a ghost after the owner
    /// deletes the original.
    func apply(_ snapshot: HouseholdSnapshot, calendarSync: CalendarSyncService) throws {
        guard snapshot.format <= HouseholdSnapshot.currentFormat else {
            throw HouseholdCrypto.Failure.cannotDecrypt
        }

        try wipe(calendarSync: calendarSync)

        for kid in snapshot.kids {
            modelContext.insert(KidRecord(id: kid.id, name: kid.name, colorHex: kid.colorHex))
        }
        for school in snapshot.schools {
            // No feed URL and no scrape config: a viewer must never fetch a
            // school's calendar itself. Its only source of truth is the
            // snapshot, and a second one would drift from it immediately.
            modelContext.insert(
                SchoolRecord(id: school.id, name: school.name, kidID: school.kidID)
            )
        }
        for defaults in snapshot.defaults {
            modelContext.insert(
                KidDayDefaults(
                    kidID: defaults.kidID,
                    breakfast: defaults.breakfast,
                    lunch: defaults.lunch,
                    clothing: defaults.clothing,
                    standingReminder: defaults.standingReminder
                )
            )
        }
        for exception in snapshot.exceptions {
            let record = DayException(
                kidID: exception.kidID,
                day: exception.day,
                field: DayField(rawValue: exception.field) ?? .reminder,
                value: exception.value,
                source: DayExceptionSource(rawValue: exception.source) ?? .email,
                provenance: exception.provenance,
                isNotable: exception.isNotable
            )
            record.id = exception.id
            modelContext.insert(record)
        }
        for event in snapshot.events {
            modelContext.insert(SchoolEventRecord(dto: event))
        }

        // Only on a viewing phone. An owner's town is their own setting and a
        // snapshot they publish must never be able to overwrite it — which it
        // could, since an owner applying their own snapshot is a thing that
        // happens the moment anyone tests the round trip.
        if ViewerSettings.role == .viewer, snapshot.place != WeatherSettings.place {
            WeatherSettings.place = snapshot.place
        }

        try modelContext.save()
    }

    /// Removes everything a snapshot owns, here and in the iOS calendar.
    ///
    /// Used both to make room for a newer snapshot and to clean up when a
    /// viewer leaves a household. The second case is why it's a method rather
    /// than the top of `apply`: a phone that has left must not keep showing a
    /// family's schedule, and by then there is no new snapshot to replace it
    /// with.
    func wipe(calendarSync: CalendarSyncService) throws {
        for event in try modelContext.fetch(FetchDescriptor<SchoolEventRecord>()) {
            if let identifier = event.calendarSyncIdentifier {
                try? calendarSync.delete(eventIdentifier: identifier)
            }
            modelContext.delete(event)
        }
        for exception in try modelContext.fetch(FetchDescriptor<DayException>()) {
            modelContext.delete(exception)
        }
        for defaults in try modelContext.fetch(FetchDescriptor<KidDayDefaults>()) {
            modelContext.delete(defaults)
        }
        for school in try modelContext.fetch(FetchDescriptor<SchoolRecord>()) {
            modelContext.delete(school)
        }
        for kid in try modelContext.fetch(FetchDescriptor<KidRecord>()) {
            modelContext.delete(kid)
        }
        try modelContext.save()
    }

    /// A viewer's whole sync: fetch, decrypt, replace.
    ///
    /// Returns false when the owner has never published — not an error, just a
    /// phone that joined before the first update, and the screen should say so.
    @discardableResult
    func refreshFromSnapshot(calendarSync: CalendarSyncService) async throws -> Bool {
        guard let client = ViewerClient.viewer(), let key = ViewerSettings.householdKey else {
            throw ViewerClient.Failure.notConfigured
        }

        guard let stored = try await client.fetchSnapshot() else { return false }

        // Nothing is touched until the payload has decrypted and decoded. A
        // wrong key must leave the viewer showing yesterday's data with an
        // error, never an emptied store that reads as "nothing unusual today".
        let snapshot = try HouseholdCrypto.open(HouseholdSnapshot.self, from: stored.payload, with: key)

        try apply(snapshot, calendarSync: calendarSync)

        ViewerSettings.snapshotVersion = stored.version
        ViewerSettings.snapshotPublishedAt = stored.publishedAt
        ViewerSettings.receivedContentVersion = snapshot.contentVersion
        return true
    }
}
