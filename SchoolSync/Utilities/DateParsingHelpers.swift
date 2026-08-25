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

    /// Tries each explicit format first, then falls back to `NSDataDetector`
    /// for loosely-formatted free text (e.g. scraped page text or email
    /// bodies where the date isn't isolated into its own element).
    static func parse(
        _ string: String,
        formats: [String] = commonFormats,
        timeZone: TimeZone = .current
    ) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        for format in formats {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            formatter.timeZone = timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = detector.firstMatch(in: trimmed, range: range) {
            return match.date
        }
        return nil
    }
}
