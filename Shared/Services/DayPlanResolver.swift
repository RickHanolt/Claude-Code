import Foundation

/// One field of one kid's day, resolved.
struct ResolvedField: Equatable, Hashable, Sendable {
    let field: DayField
    let value: String

    /// False when this is just the baseline. Morning Mode leans on this: the
    /// whole point of the screen is that a normal day should be quiet and an
    /// unusual one should be obvious, so only exceptions get emphasis.
    let isException: Bool

    /// Why the baseline was overridden, in prose. Nil for a plain default.
    let provenance: String?
}

/// Everything Morning Mode needs for one kid on one day.
struct DayPlan: Equatable, Sendable {
    let kidID: UUID
    let day: Date
    let breakfast: ResolvedField
    let lunch: ResolvedField
    let clothing: ResolvedField

    /// Reminders accumulate rather than override — a jeans day and a field trip
    /// on the same date are both true and a parent needs both. This is the one
    /// field where "last writer wins" would lose real information.
    let reminders: [ResolvedField]

    var hasExceptions: Bool {
        breakfast.isException || lunch.isException || clothing.isException
            || reminders.contains { $0.isException }
    }
}

/// Resolves a kid's day as "the baseline, unless something says otherwise".
///
/// Deliberately a pure function over values rather than something that reaches
/// into SwiftData: the interesting behaviour is the precedence order, and that
/// deserves to be testable without a database, a device, or a fixture store.
enum DayPlanResolver {
    /// Precedence when two sources disagree about the same field on the same
    /// day, most trusted first.
    ///
    /// A typed-in value always wins: if the user corrected something, a later
    /// sync re-reading the same menu must not silently undo it. Published
    /// schedules beat email prose because a menu is a table and a newsletter is
    /// a sentence somebody wrote in a hurry — and the extraction reading that
    /// sentence is the least certain link in the chain.
    private static func rank(_ source: DayExceptionSource) -> Int {
        switch source {
        case .manual: 0
        case .schedule: 1
        case .email: 2
        }
    }

    static func resolve(
        kidID: UUID,
        day: Date,
        defaults: KidDayDefaults?,
        exceptions: [DayException],
        calendar: Calendar = .current
    ) -> DayPlan {
        let startOfDay = calendar.startOfDay(for: day)

        let relevant = exceptions.filter {
            $0.kidID == kidID && calendar.isDate($0.day, inSameDayAs: startOfDay)
        }

        func resolveSingle(_ field: DayField) -> ResolvedField {
            let baseline = defaults?.value(for: field) ?? ""

            // Sorted by trust, then take the first: a stable choice, and one
            // that doesn't depend on what order the caller happened to fetch
            // rows in.
            let winner = relevant
                .filter { $0.field == field && !$0.value.isEmpty }
                .min { rank($0.source) < rank($1.source) }

            guard let winner else {
                return ResolvedField(field: field, value: baseline, isException: false, provenance: nil)
            }

            return ResolvedField(
                field: field,
                value: winner.value,
                // An exception that merely restates the default is not news.
                // A menu confirming "packs lunch" on a Tuesday shouldn't light
                // up a screen designed so that emphasis means "something is
                // different today".
                isException: winner.value != baseline,
                provenance: winner.provenance
            )
        }

        let standing = defaults?.standingReminder
        var reminders: [ResolvedField] = []

        if let standing, !standing.isEmpty {
            reminders.append(
                ResolvedField(field: .reminder, value: standing, isException: false, provenance: nil)
            )
        }

        // Every reminder for the day, most trusted first, deduplicated on text
        // so the same note arriving from an email and a schedule reads once.
        var seen = Set<String>()
        for exception in relevant.filter({ $0.field == .reminder && !$0.value.isEmpty })
            .sorted(by: { rank($0.source) < rank($1.source) }) {
            let key = exception.value.lowercased()
            guard !seen.contains(key), key != standing?.lowercased() else { continue }
            seen.insert(key)
            reminders.append(
                ResolvedField(
                    field: .reminder,
                    value: exception.value,
                    isException: true,
                    provenance: exception.provenance
                )
            )
        }

        return DayPlan(
            kidID: kidID,
            day: startOfDay,
            breakfast: resolveSingle(.breakfast),
            lunch: resolveSingle(.lunch),
            clothing: resolveSingle(.clothing),
            reminders: reminders
        )
    }
}
