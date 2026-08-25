import Foundation

enum DateParsingHelpers {
    /// Formats tried in order when no explicit `ScrapeConfig.dateFormat` is
    /// given. Covers the common shapes school calendar sites tend to use.
    static let commonFormats: [String] = [
        "EEEE, MMMM d, yyyy 'at' h:mm a",
        "MMMM d, yyyy 'at' h:mm a",
        "MMMM d, yyyy h:mm a",
        "EEEE, MMMM d, yyyy",
        "MMMM d, yyyy",
        "MMM d, yyyy h:mm a",
        "MMM d, yyyy",
        "M/d/yyyy h:mm a",
        "M/d/yyyy",
        "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
    ]

    struct ParsedDate {
        let date: Date
        /// Whether the matched text actually specified a time of day, as
        /// opposed to defaulting to midnight. Callers use this to decide
        /// `SchoolEventDTO.isAllDay` — without it, a scraped "Back to School
        /// Night at 6:30 PM" would silently lose its time and show as an
        /// all-day event.
        let hasTimeComponent: Bool
    }

    /// Convenience wrapper over `parseDetailed` for callers that only need
    /// the date.
    static func parse(
        _ string: String,
        formats: [String] = commonFormats,
        timeZone: TimeZone = .current
    ) -> Date? {
        parseDetailed(string, formats: formats, timeZone: timeZone)?.date
    }

    /// Tries each explicit format first, then falls back to `NSDataDetector`
    /// for loosely-formatted free text (e.g. scraped page text or email
    /// bodies where the date isn't isolated into its own element).
    static func parseDetailed(
        _ string: String,
        formats: [String] = commonFormats,
        timeZone: TimeZone = .current
    ) -> ParsedDate? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for format in formats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: trimmed) {
                let hasTime = format.contains("H") || format.contains("h")
                return ParsedDate(date: date, hasTimeComponent: hasTime)
            }
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range), let date = match.date else {
            return nil
        }

        let matchedText = Range(match.range, in: trimmed).map { String(trimmed[$0]) } ?? ""
        let hasTime = matchedText.contains(":")
            || matchedText.range(of: "am", options: [.caseInsensitive]) != nil
            || matchedText.range(of: "pm", options: [.caseInsensitive]) != nil
        return ParsedDate(date: date, hasTimeComponent: hasTime)
    }
}
