import Foundation
import CryptoKit

extension String {
    /// Short, stable hash used as a de-dup identifier for events that don't
    /// come with their own UID (scraped events, confirmed email events).
    /// Callers build the input string from fields that identify the event
    /// (school + title + start date) so re-scraping/re-parsing the same
    /// event produces the same id and upserts instead of duplicating.
    var stableID: String {
        let digest = SHA256.hash(data: Data(utf8))
        return digest.map { String(format: "%02x", $0) }.prefix(24).description
    }

    /// Very small HTML-tag stripper for share-extension text extraction,
    /// where we just need readable text to run a date detector over — not a
    /// full HTML parser (that's SwiftSoup's job for scraping).
    func strippingHTMLTags() -> String {
        let withoutTags = replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
