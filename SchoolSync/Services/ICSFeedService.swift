import Foundation

/// Why a feed didn't produce events.
///
/// `LocalizedError` rather than a bare enum: the sync screen shows
/// `error.localizedDescription`, and Foundation renders a plain Swift error as
/// "The operation couldn't be completed", which is how a school calendar can be
/// broken for months without anyone being told anything useful.
enum ICSFeedError: LocalizedError {
    case badResponse(status: Int)
    case decodingFailed
    /// Fetched fine, but what came back isn't an iCalendar document at all.
    case notACalendar(looksLike: String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let status):
            "the server returned HTTP \(status)."
        case .decodingFailed:
            "the response wasn't readable as text."
        case .notACalendar(let looksLike):
            "this isn't a calendar feed — it looks like \(looksLike). Look for an \"iCal\", \"Subscribe\" or \".ics\" link on the school's calendar page."
        }
    }
}

struct ICSFeedService {
    func fetchEvents(from url: URL, kidID: UUID, schoolID: UUID) async throws -> [SchoolEventDTO] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ICSFeedError.badResponse(status: http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ICSFeedError.decodingFailed
        }

        // Check the document is a calendar before parsing it, because the
        // parser cannot fail — it scans for BEGIN:VEVENT and returns whatever
        // it finds, which for a news feed or a web page is nothing at all. A
        // successful fetch that yields zero events is indistinguishable from a
        // calendar with nothing in it, so a school's URL can be wrong for
        // months while every sync reports success.
        //
        // This is exactly what happened: a school was configured with its
        // site's news RSS endpoint instead of its calendar, and the app had no
        // way to say so.
        guard text.contains("BEGIN:VCALENDAR") else {
            throw ICSFeedError.notACalendar(looksLike: describeDocument(text))
        }

        return ICSParser.parse(text, kidID: kidID, schoolID: schoolID)
    }

    /// A short, plain description of what the URL returned instead, so the
    /// message names the actual mistake rather than restating the failure.
    private func describeDocument(_ text: String) -> String {
        let head = text.prefix(400).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if head.contains("<rss") || head.contains("<feed") { return "a news feed (RSS)" }
        if head.hasPrefix("<!doctype html") || head.contains("<html") { return "a web page" }
        if head.hasPrefix("{") || head.hasPrefix("[") { return "JSON" }
        if head.hasPrefix("<?xml") { return "an XML document" }
        return "something else"
    }
}
