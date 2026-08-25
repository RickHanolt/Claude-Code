import Foundation

/// Per-school configuration for scraping a calendar page with SwiftSoup.
///
/// There's no generic way to scrape an arbitrary school calendar page, so this
/// is intentionally selector-driven: open the school's calendar page, inspect
/// the HTML, and fill these in. `titleSelector`, `dateSelector`, and
/// `locationSelector` are resolved *relative to* each element matched by
/// `eventContainerSelector`.
struct ScrapeConfig: Codable, Hashable, Sendable {
    /// CSS selector matching each event's row/card, e.g. ".fsCalendarInfo" or
    /// "[data-testid='event-row']".
    var eventContainerSelector: String

    /// Selector for the title, relative to the container. If nil, the
    /// container's own text is used as the title.
    var titleSelector: String?

    /// Selector for the date/time, relative to the container. If nil, the
    /// container's own text is scanned for a date.
    var dateSelector: String?

    /// If the date lives in an HTML attribute (e.g. `data-date="2026-09-02"`)
    /// rather than the element's text, name the attribute here.
    var dateAttribute: String?

    /// Selector for the location, relative to the container.
    var locationSelector: String?

    /// Optional explicit `DateFormatter` format string. When nil, several
    /// common formats are tried automatically (see `DateParsingHelpers`).
    var dateFormat: String?
}
