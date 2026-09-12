import Foundation

/// Deciding whether two events from *different* sources are the same event.
///
/// Pulaski's calendar feed and a forwarded school newsletter both describe the
/// same picture day, and until now each produced its own row: they're matched
/// on `externalID`, and a feed UID never equals a hash of an email's subject.
/// One event, two lines, on the screen whose entire value is that a line means
/// something.
///
/// The rules below are deliberately strict, because the two ways of being
/// wrong are not equally bad. Showing a duplicate is untidy and self-evident.
/// Hiding a real event is invisible, and this app exists so a parent doesn't
/// send a child to school on a day it's closed. Every rule here therefore
/// fails toward showing both.
///
/// Not executable in this repo — there's no Swift toolchain on the build host
/// and no test target. The rule was instead mirrored line-for-line in a scratch
/// script and exercised against real rows from this household's calendar, then
/// mutation-tested: removing any single guard below turns one of these cases
/// red, and so does swapping containment for Jaccard. That validates the logic,
/// not this code — the Swift itself is first exercised on device.
///
/// The cases the rule must satisfy, kept here because they're the only record
/// of why each guard exists:
///
/// Must match:
/// - "No School - Labor Day" all-day from a feed, and the same title all-day
///   from an email anchored at noon rather than midnight.
/// - "Curriculum Night (Meet the Teacher)" and "Curriculum Night", both 5pm.
/// - "Picture Day" and "Fall Picture Day (bring order forms)", both all-day.
///
/// Must NOT match:
/// - "Basketball Skills Program K-3rd" at 3pm and "…4th-8th (4-5 PM)" at 4pm.
/// - The same two cohorts if they ever shared a start time.
/// - "Session 1 of the Fall Basketball Skills Program" and "Session 2 of …",
///   which agree on seven words out of eight.
/// - "Curriculum Night" at 5pm and "Curriculum Night" at 7pm.
/// - "Band Concert" and "Band Practice".
/// - "Assembly" and "Fall Assembly Rehearsal".
/// - An all-day "Picture Day" and a 3pm one.
///
/// Accepted misses: "Fall Picture Day" and "School Pictures" share no words and
/// stay separate. Two rows is the failure this is allowed to have.
enum EventMatching {
    /// Trust order when two sources disagree, most trusted first.
    ///
    /// A feed is a table the school publishes. An email is prose a person wrote
    /// and a model read. When both describe one event, the feed's version of
    /// the title and time is the one to keep.
    static func rank(_ source: EventSourceType) -> Int {
        switch source {
        case .icsFeed: 0
        case .webScrape: 1
        case .emailForward: 2
        }
    }

    /// Lowercased alphanumeric words. Punctuation becomes whitespace, so
    /// "4th-8th" and "(3-4 PM)" split into their parts rather than surviving
    /// as opaque blobs that would never match anything.
    static func tokens(_ title: String) -> [String] {
        let flattened = String(
            title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character(" ") }
        )
        return flattened.split(separator: " ").map(String.init)
    }

    /// Tokens containing a digit — grade bands, session numbers, times.
    ///
    /// These are how a school calendar distinguishes events that are otherwise
    /// worded identically: "Basketball Skills Program K-3rd" and "Basketball
    /// Skills Program 4th-8th" share every word that isn't a number. Requiring
    /// these to match exactly is what stops one cohort's event from swallowing
    /// another's.
    static func digitTokens(_ tokens: [String]) -> Set<String> {
        Set(tokens.filter { $0.contains(where: \.isNumber) })
    }

    /// How much of the shorter title appears in the longer one.
    ///
    /// Containment rather than Jaccard: a feed's terse "Picture Day" against an
    /// email's "Fall Picture Day (bring order forms)" should score high, and
    /// Jaccard would punish it for the extra words that are exactly what makes
    /// the email version wordier.
    static func containment(_ a: [String], _ b: [String]) -> Double {
        let shorter = a.count <= b.count ? Set(a) : Set(b)
        let longer = a.count <= b.count ? Set(b) : Set(a)
        guard !shorter.isEmpty else { return 0 }
        return Double(shorter.intersection(longer).count) / Double(shorter.count)
    }

    /// Whether two events describe the same thing. Every condition is required.
    static func isSameEvent(
        titleA: String,
        startA: Date,
        isAllDayA: Bool,
        titleB: String,
        startB: Date,
        isAllDayB: Bool,
        calendar: Calendar = .current
    ) -> Bool {
        // Same day, not same instant. An all-day event from a feed sits at
        // local midnight; one from extraction is anchored at noon so it can't
        // slide backwards a day when rendered. Same date, hours apart.
        guard calendar.isDate(startA, inSameDayAs: startB) else { return false }

        // An all-day "Picture Day" and a 3pm "Picture Day Retakes" are not the
        // same event, and this is the cheapest way to know it.
        guard isAllDayA == isAllDayB else { return false }

        // Two timed events on one day are the same event only if they start at
        // the same time. This is what keeps the 3pm and 4pm sessions of one
        // after-school program apart.
        if !isAllDayA {
            let a = calendar.dateComponents([.hour, .minute], from: startA)
            let b = calendar.dateComponents([.hour, .minute], from: startB)
            guard a.hour == b.hour, a.minute == b.minute else { return false }
        }

        let tokensA = tokens(titleA)
        let tokensB = tokens(titleB)

        // A one-word title is contained in almost anything — "Assembly" sits
        // inside "Fall Assembly Rehearsal" at a perfect score. Refuse to judge.
        guard min(tokensA.count, tokensB.count) >= 2 else { return false }

        guard digitTokens(tokensA) == digitTokens(tokensB) else { return false }

        // 0.8 rather than something looser: at this point the day, the all-day
        // flag, the start time and every number already agree, so the titles
        // only have to corroborate — and a threshold that lets two genuinely
        // different events through has no later check to catch it.
        return containment(tokensA, tokensB) >= 0.8
    }
}
