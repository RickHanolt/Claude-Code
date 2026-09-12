import Foundation
import SwiftData

/// Writes one backend-received email into the local store: its events, its day
/// exceptions, and the email itself.
///
/// Extracted from `PendingReviewView` because a second caller now exists — mail
/// from a sender whose kid is already known is saved without anyone tapping
/// through the review screen. Two copies of this logic would drift the first
/// time either one gained a field, and the drift would be silent: one path
/// would quietly stop saving something the other still did.
@MainActor
struct PendingIngestor {
    let modelContext: ModelContext

    /// What was written, so a caller can acknowledge exactly these ids and
    /// report honestly about what it did without being asked to.
    struct Saved {
        var eventIDs: [String] = []
        var exceptionIDs: [String] = []
        var eventCount: Int { eventIDs.count }
    }

    @discardableResult
    func save(
        email: PendingForwardedEmail,
        candidates: [PendingCandidateEvent],
        checkedEventIDs: Set<String>,
        exceptions: [PendingCandidateException],
        kidID: UUID,
        schoolID: UUID
    ) -> Saved {
        let checked = candidates.filter { checkedEventIDs.contains($0.id) }

        let eventDTOs = checked.map { candidate in
            SchoolEventDTO(
                id: "\(schoolID):\(candidate.title):\(candidate.startDate.timeIntervalSince1970)".stableID,
                title: candidate.title,
                startDate: candidate.startDate,
                endDate: candidate.endDate,
                isAllDay: candidate.isAllDayEvent,
                location: nil,
                notes: candidate.notes,
                kidID: kidID,
                schoolID: schoolID,
                source: .emailForward
            )
        }

        let emailDTO = ForwardedEmailDTO(
            id: email.id,
            subject: email.subject,
            bodyText: email.bodyText,
            sharedDate: email.receivedAt,
            kidID: kidID,
            schoolID: schoolID
        )

        let store = EventStore(modelContext: modelContext)
        try? store.upsert(eventDTOs)
        try? store.insertForwardedEmailIfNeeded(emailDTO)

        saveExceptions(exceptions, kidID: kidID, subject: email.subject)

        return Saved(
            eventIDs: checked.map(\.id),
            exceptionIDs: exceptions.map(\.id)
        )
    }

    /// Writes day exceptions, upserted by identity rather than inserted, so
    /// re-reading a month that has been corrected once doesn't stack a second
    /// opinion about the same day on top of the first.
    ///
    /// A manual edit is never overwritten. If someone fixed a day by hand, a
    /// later document re-stating the original is not new information, and
    /// silently undoing their correction is the fastest way to make the screen
    /// untrustworthy.
    func saveExceptions(
        _ exceptions: [PendingCandidateException],
        kidID: UUID,
        subject: String
    ) {
        guard !exceptions.isEmpty else { return }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        // The day string is a wall-clock date with no zone, so parse it in the
        // device's own calendar rather than UTC — otherwise "pack a lunch on
        // the 9th" lands on the 8th for anyone west of Greenwich.
        formatter.timeZone = calendar.timeZone

        let existing = (try? modelContext.fetch(FetchDescriptor<DayException>())) ?? []

        for exception in exceptions {
            guard let day = formatter.date(from: exception.day) else { continue }
            let startOfDay = calendar.startOfDay(for: day)

            let identity = DayException.identity(
                kidID: kidID,
                day: startOfDay,
                field: exception.dayFieldValue,
                source: .email
            )

            let hasManualOverride = existing.contains {
                $0.kidID == kidID
                    && calendar.isDate($0.day, inSameDayAs: startOfDay)
                    && $0.field == exception.dayFieldValue
                    && $0.source == .manual
            }
            if hasManualOverride { continue }

            if let match = existing.first(where: { $0.id == identity }) {
                match.value = exception.value
                match.provenance = exception.note ?? subject
                match.isNotable = exception.isNotableException
            } else {
                modelContext.insert(
                    DayException(
                        kidID: kidID,
                        day: startOfDay,
                        field: exception.dayFieldValue,
                        value: exception.value,
                        source: .email,
                        provenance: exception.note ?? subject,
                        isNotable: exception.isNotableException
                    )
                )
            }
        }

        try? modelContext.save()
    }
}
