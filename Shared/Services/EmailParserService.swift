import Foundation

/// Heuristic extraction for forwarded/shared emails: scans the body for
/// dates with `NSDataDetector` and surfaces each hit as a candidate event
/// titled after the email subject, for the user to review and confirm in
/// the share extension's UI (`ShareConfirmationView`) — this deliberately
/// does not auto-save anything, since a bare date detector will produce
/// false positives on emails with unrelated dates in them (e.g. "since
/// 1998").
struct EmailParserService {
    /// Matches landing on the same calendar day as `referenceDate` (the
    /// moment you're sharing the email) are suppressed by default. In
    /// practice these are almost always publish/send-date metadata a
    /// templated newsletter embeds in its body (a "Posted on [date]" line,
    /// for instance) rather than a real same-day event notice — you're
    /// rarely forwarding an email about something happening literally today.
    /// This trades away genuine same-day event detection for far fewer
    /// false positives from newsletter boilerplate, which is the more
    /// common case in practice.
    func extractCandidateEvents(
        subject: String,
        bodyText: String,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> [ParsedCandidateEvent] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }

        let range = NSRange(bodyText.startIndex..., in: bodyText)
        let matches = detector.matches(in: bodyText, range: range)

        var seenStarts = Set<TimeInterval>()
        var results: [ParsedCandidateEvent] = []

        for match in matches {
            guard let date = match.date else { continue }
            guard !calendar.isDate(date, inSameDayAs: referenceDate) else { continue }
            guard seenStarts.insert(date.timeIntervalSince1970).inserted else { continue }

            let end = match.duration > 0 ? date.addingTimeInterval(match.duration) : nil
            let snippet = surroundingSnippet(for: match, in: bodyText)

            results.append(
                ParsedCandidateEvent(
                    title: subject.isEmpty ? "Forwarded event" : subject,
                    startDate: date,
                    endDate: end,
                    notes: snippet
                )
            )
        }

        return results
    }

    /// Grabs a short window of context around the matched date so the
    /// confirmation screen can show *why* this date was picked out, trimmed
    /// to whole words on each side rather than cutting mid-word.
    private func surroundingSnippet(for match: NSTextCheckingResult, in text: String) -> String? {
        guard let range = Range(match.range, in: text) else { return nil }
        let padding = 30

        var lowerBound = text.index(range.lowerBound, offsetBy: -padding, limitedBy: text.startIndex) ?? text.startIndex
        if lowerBound != text.startIndex {
            lowerBound = text[text.startIndex..<lowerBound].lastIndex(of: " ").map { text.index(after: $0) } ?? lowerBound
        }

        var upperBound = text.index(range.upperBound, offsetBy: padding, limitedBy: text.endIndex) ?? text.endIndex
        if upperBound != text.endIndex {
            upperBound = text[upperBound...].firstIndex(of: " ") ?? upperBound
        }

        let snippet = text[lowerBound..<upperBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return snippet.isEmpty ? nil : snippet
    }
}
