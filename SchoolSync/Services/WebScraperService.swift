import Foundation
import SwiftSoup

enum ScrapeError: Error {
    case badResponse
    case decodingFailed
}

/// Scrapes a school calendar page using a per-school `ScrapeConfig`. This is
/// the fragile ingestion path: it only works as well as the selectors you
/// give it, and will silently return zero events (not throw) for any row
/// where a date can't be parsed, so a school redesigning their page shows up
/// as "sync ran, found nothing" rather than a crash — check Settings for the
/// last-sync event count if a school stops showing new events.
struct WebScraperService {
    func scrapeEvents(
        from url: URL,
        config: ScrapeConfig,
        kidID: UUID,
        schoolID: UUID
    ) async throws -> [SchoolEventDTO] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ScrapeError.badResponse
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw ScrapeError.decodingFailed
        }

        let document = try SwiftSoup.parse(html, url.absoluteString)
        let containers = try document.select(config.eventContainerSelector)

        var results: [SchoolEventDTO] = []
        for container in containers.array() {
            guard let dto = try makeEvent(container: container, config: config, kidID: kidID, schoolID: schoolID) else {
                continue
            }
            results.append(dto)
        }
        return results
    }

    private func makeEvent(
        container: Element,
        config: ScrapeConfig,
        kidID: UUID,
        schoolID: UUID
    ) throws -> SchoolEventDTO? {
        let title: String
        if let selector = config.titleSelector, let element = try container.select(selector).first() {
            title = try element.text()
        } else {
            title = try container.text()
        }
        guard !title.isEmpty else { return nil }

        let dateString: String?
        if let selector = config.dateSelector {
            guard let element = try container.select(selector).first() else { return nil }
            if let attribute = config.dateAttribute {
                dateString = try element.attr(attribute)
            } else {
                dateString = try element.text()
            }
        } else {
            dateString = try container.text()
        }
        guard let dateString else { return nil }

        let formats = config.dateFormat.map { [$0] } ?? DateParsingHelpers.commonFormats
        guard let parsedDate = DateParsingHelpers.parseDetailed(dateString, formats: formats) else { return nil }
        let startDate = parsedDate.date

        let location: String?
        if let selector = config.locationSelector, let element = try container.select(selector).first() {
            location = try element.text()
        } else {
            location = nil
        }

        let externalID = "\(schoolID):\(title):\(startDate.timeIntervalSince1970)".stableID

        return SchoolEventDTO(
            id: externalID,
            title: title,
            startDate: startDate,
            endDate: nil,
            isAllDay: !parsedDate.hasTimeComponent,
            location: location,
            notes: nil,
            kidID: kidID,
            schoolID: schoolID,
            source: .webScrape
        )
    }
}
