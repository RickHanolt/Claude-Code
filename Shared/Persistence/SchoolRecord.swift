import Foundation
import SwiftData

@Model
final class SchoolRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var kidID: UUID

    /// Set when this school publishes an ICS calendar feed.
    var icsFeedURLString: String?

    /// Set when this school's calendar page should be scraped instead.
    var scrapeURLString: String?
    private var scrapeConfigData: Data?

    /// Whether this school appears as a destination in the share-extension
    /// confirmation screen for forwarded emails.
    var acceptsEmailForwarding: Bool

    init(
        id: UUID = UUID(),
        name: String,
        kidID: UUID,
        icsFeedURLString: String? = nil,
        scrapeURLString: String? = nil,
        scrapeConfig: ScrapeConfig? = nil,
        acceptsEmailForwarding: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kidID = kidID
        self.icsFeedURLString = icsFeedURLString
        self.scrapeURLString = scrapeURLString
        self.acceptsEmailForwarding = acceptsEmailForwarding
        self.scrapeConfigData = scrapeConfig.flatMap { try? JSONEncoder().encode($0) }
    }

    var icsFeedURL: URL? {
        icsFeedURLString.flatMap(URL.init(string:))
    }

    var scrapeURL: URL? {
        scrapeURLString.flatMap(URL.init(string:))
    }

    var scrapeConfig: ScrapeConfig? {
        get { scrapeConfigData.flatMap { try? JSONDecoder().decode(ScrapeConfig.self, from: $0) } }
        set { scrapeConfigData = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }
}
