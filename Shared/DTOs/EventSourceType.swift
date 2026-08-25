import Foundation

/// Where a `SchoolEventDTO` was produced from. Kept on the persisted record too,
/// mostly so the UI can show a small badge explaining why an event showed up.
enum EventSourceType: String, Codable, Sendable {
    case icsFeed
    case webScrape
    case emailForward
}
