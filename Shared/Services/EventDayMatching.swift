import Foundation

/// Whether an event falls on a given day.
///
/// Pulled out of the view that used to own it so it can be asserted against
/// without a simulator, a database, or a screenshot. The rule it replaced —
/// compare the start date and nothing else — compiled cleanly for months and
/// was wrong the entire time: a break spanning a week announced itself on the
/// Monday and vanished for the other four days, and because field suppression
/// keys off finding a closure among the day's lines, the screen then asserted
/// an ordinary school morning in its place.
///
/// A pure function over values, which is the only reason that failure is
/// catchable in a test at all.
enum EventDayMatching {
    /// - Parameters:
    ///   - end: The event's last day, inclusive. Nil for a row that carries no
    ///     end, which is treated as a single day.
    static func occurs(on day: Date, start: Date, end: Date?, calendar: Calendar = .current) -> Bool {
        let target = calendar.startOfDay(for: day)
        let first = calendar.startOfDay(for: start)

        guard let end else { return first == target }

        let last = calendar.startOfDay(for: end)

        // An end before its start is bad data, not an empty range. Falling back
        // to the start day keeps the row visible on one day rather than hiding
        // it from every day at once — the failure mode that would be silent.
        guard last >= first else { return first == target }

        return target >= first && target <= last
    }

    /// Whether this day is the one the event begins on.
    ///
    /// Separates news from context. A span is worth the parent's attention the
    /// morning it starts; on the days after, it is background — still true,
    /// still worth printing, but not worth competing with the thing that
    /// changed today.
    ///
    /// The exception is a closure, which the caller adds: school being shut is
    /// something you act on every morning of it, not an announcement made once.
    static func isFirstDay(on day: Date, start: Date, calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: day) == calendar.startOfDay(for: start)
    }
}
