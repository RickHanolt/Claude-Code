import Foundation

/// Heuristic extraction for forwarded/shared emails: scans the body for
/// dates with `NSDataDetector` and surfaces each hit as a candidate event
/// titled after the email subject, for the user to review and confirm in
/// the share extension's UI (`ShareConfirmationView`) — this deliberately
/// does not auto-save anything, since a bare date detector will produce
/// false positives on emails with unrelated dates in them (e.g. "since
/// 1998").
struct EmailParserService {
    func extractCandidateEvents(subject: String, bodyText: String) -> [ParsedCandidateEvent] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }

        let range = NSRange(bodyText.startIndex..., in: bodyText)
        let matches = detector.matches(in: bodyText, range: range)

        var seenStarts = Set<TimeInterval>()
        var results: [ParsedCandidateEvent] = []

        for match in matches {
            guard let date = match.date else { continue }
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

    /// Grabs ~80 characters of context around the matched date so the
    /// confirmation screen can show *why* this date was picked out.
    private func surroundingSnippet(for match: NSTextCheckingResult, in text: String) -> String? {
        guard let range = Range(match.range, in: text) else { return nil }
        let padding = 40
        let lowerBound = text.index(range.lowerBound, offsetBy: -padding, limitedBy: text.startIndex) ?? text.startIndex
        let upperBound = text.index(range.upperBound, offsetBy: padding, limitedBy: text.endIndex) ?? text.endIndex
        let snippet = text[lowerBound..<upperBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }
}
