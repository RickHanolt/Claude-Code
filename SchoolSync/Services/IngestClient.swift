import Foundation

/// An email the Ingest backend received and hasn't been acknowledged yet —
/// mirrors a row in the Worker's `forwarded_emails` table
/// (`Ingest/migrations/0001_init.sql`).
struct PendingForwardedEmail: Codable, Identifiable, Hashable {
    var id: String
    var sender: String?
    var subject: String
    var bodyText: String
    var receivedAt: Date
}

/// A date candidate the backend's heuristic (`Ingest/src/dateParser.ts`)
/// found in a pending email, awaiting the same kind of confirmation the
/// share extension asks for.
struct PendingCandidateEvent: Codable, Identifiable, Hashable {
    var id: String
    var forwardedEmailId: String
    var title: String
    var startDate: Date
    var endDate: Date?
    var notes: String?

    /// Optional so a response from a backend that predates this field still
    /// decodes — JSONDecoder fails the entire response on one missing required
    /// key, which would hide every email behind a parse error rather than
    /// degrading one field. Read it through `isAllDayEvent`, never directly.
    var isAllDay: Bool?

    /// All-day per the backend, falling back to the old inference.
    ///
    /// "No end time given" and "no time given at all" are different things, and
    /// conflating them rendered a multi-day testing window as "12:00 PM" — the
    /// local-noon anchor showing through as if it were a real start time. The
    /// model now states which it meant; the fallback only applies to events
    /// extracted before it did.
    var isAllDayEvent: Bool { isAllDay ?? (endDate == nil) }
}

struct PendingResponse: Codable {
    var emails: [PendingForwardedEmail]
    var events: [PendingCandidateEvent]
}

enum IngestClientError: Error {
    case notConfigured
    case unauthorized
    case server(Int)
}

/// Talks to the Cloudflare Worker backend described in INGEST_BACKEND.md.
/// Does nothing (and is never constructed) unless the user has opted in via
/// Settings — see `IngestSettings.isConfigured`.
struct IngestClient {
    let baseURL: URL
    let apiKey: String

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func fetchPending() async throws -> PendingResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/pending"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
        return try decoder.decode(PendingResponse.self, from: data)
    }

    /// Tells the backend these emails/events have been pulled into the
    /// local store, so the next `fetchPending()` doesn't return them again.
    func acknowledge(emailIDs: [String], eventIDs: [String]) async throws {
        guard !emailIDs.isEmpty || !eventIDs.isEmpty else { return }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/ack"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["emailIds": emailIDs, "eventIds": eventIDs])

        let (_, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response)
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw IngestClientError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw IngestClientError.server(http.statusCode) }
    }

    /// Returns nil (rather than throwing) when the feature isn't set up, so
    /// call sites can treat "not configured" the same as "nothing pending".
    static func configured() -> IngestClient? {
        guard let baseURL = IngestSettings.baseURL, let apiKey = IngestSettings.apiKey, !apiKey.isEmpty else {
            return nil
        }
        return IngestClient(baseURL: baseURL, apiKey: apiKey)
    }
}
