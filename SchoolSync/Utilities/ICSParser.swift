import Foundation

/// Minimal RFC 5545 (iCalendar) parser covering what school calendar feeds
/// actually use in practice: VEVENT blocks with UID/SUMMARY/DTSTART/DTEND/
/// LOCATION/DESCRIPTION. Not a full spec implementation (no recurrence
/// expansion, no VALARM, no VTIMEZONE resolution beyond a best-effort
/// UTC/offset read) — good enough for reading events out of a feed, not for
/// round-tripping calendars.
enum ICSParser {
    static func parse(_ text: String, kidID: UUID, schoolID: UUID) -> [SchoolEventDTO] {
        let lines = unfold(text)
        var events: [SchoolEventDTO] = []
        var current: [String: (params: [String: String], value: String)] = [:]
        var inEvent = false

        for line in lines {
            if line == "BEGIN:VEVENT" {
                inEvent = true
                current = [:]
                continue
            }
            if line == "END:VEVENT" {
                inEvent = false
                if let dto = makeEvent(from: current, kidID: kidID, schoolID: schoolID) {
                    events.append(dto)
                }
                continue
            }
            guard inEvent else { continue }
            guard let (name, params, value) = parseContentLine(line) else { continue }
            current[name] = (params, value)
        }

        return events
    }

    /// Un-folds continuation lines (a line starting with a space or tab
    /// continues the previous line, per RFC 5545 §3.1) and normalizes
    /// line endings.
    private static func unfold(_ text: String) -> [String] {
        let rawLines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var result: [String] = []
        for line in rawLines {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !result.isEmpty {
                result[result.count - 1] += line.dropFirst()
            } else if !line.isEmpty {
                result.append(line)
            }
        }
        return result
    }

    /// Parses a single "NAME;PARAM=VALUE;PARAM2=VALUE2:content" line.
    private static func parseContentLine(_ line: String) -> (name: String, params: [String: String], value: String)? {
        guard let colonIndex = line.firstIndex(of: ":") else { return nil }
        let head = line[line.startIndex..<colonIndex]
        let value = String(line[line.index(after: colonIndex)...])

        let parts = head.components(separatedBy: ";")
        guard let name = parts.first?.uppercased() else { return nil }

        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            let kv = part.components(separatedBy: "=")
            if kv.count == 2 {
                params[kv[0].uppercased()] = kv[1]
            }
        }
        return (name, params, unescape(value))
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func makeEvent(
        from fields: [String: (params: [String: String], value: String)],
        kidID: UUID,
        schoolID: UUID
    ) -> SchoolEventDTO? {
        guard let summary = fields["SUMMARY"]?.value, !summary.isEmpty else { return nil }
        guard let dtstart = fields["DTSTART"] else { return nil }

        let (startDate, isAllDay) = parseICSDate(dtstart.value, params: dtstart.params)
        guard let startDate else { return nil }

        var endDate: Date?
        if let dtend = fields["DTEND"] {
            endDate = parseICSDate(dtend.value, params: dtend.params).0
        }

        let uid = fields["UID"]?.value ?? "\(schoolID):\(summary):\(startDate.timeIntervalSince1970)".stableID

        return SchoolEventDTO(
            id: uid,
            title: summary,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            location: fields["LOCATION"]?.value,
            notes: fields["DESCRIPTION"]?.value,
            kidID: kidID,
            schoolID: schoolID,
            source: .icsFeed
        )
    }

    /// Returns (date, isAllDay). Handles `VALUE=DATE` (all-day, "yyyyMMdd"),
    /// floating/local "yyyyMMdd'T'HHmmss", and UTC "yyyyMMdd'T'HHmmss'Z'".
    /// TZID-qualified times are parsed as local time (no timezone database
    /// lookup) — close enough for a school calendar, not exact for events
    /// crossing a DST boundary in a different timezone than the device.
    private static func parseICSDate(_ value: String, params: [String: String]) -> (Date?, Bool) {
        if params["VALUE"] == "DATE" || (value.count == 8 && !value.contains("T")) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            return (formatter.date(from: value), true)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = .current
        }
        return (formatter.date(from: value), false)
    }
}
