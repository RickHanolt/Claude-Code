import Foundation

/// Talks to the viewer endpoints (see VIEWER_MODE.md).
///
/// Two credentials, never mixed: the household API key for everything an owner
/// does, a viewer token for the two things a viewer may do. Each initialiser
/// below can only build one kind of client, so a viewer call can't accidentally
/// be made with an owner key.
struct ViewerClient {
    enum Failure: LocalizedError {
        case notConfigured
        case server(Int)
        case inviteRejected

        var errorDescription: String? {
            switch self {
            case .notConfigured: "this phone isn't set up to sync yet."
            case .server(let status): "the server returned HTTP \(status)."
            case .inviteRejected: "that code has already been used or has expired."
            }
        }
    }

    let baseURL: URL
    let token: String

    static func owner() -> ViewerClient? {
        guard let baseURL = IngestSettings.baseURL, let key = IngestSettings.apiKey, !key.isEmpty else { return nil }
        return ViewerClient(baseURL: baseURL, token: key)
    }

    static func viewer() -> ViewerClient? {
        guard let baseURL = ViewerSettings.viewerBaseURL,
              let token = ViewerSettings.viewerToken, !token.isEmpty
        else { return nil }
        return ViewerClient(baseURL: baseURL, token: token)
    }

    private func request(_ path: String, method: String, body: (some Encodable)? = Optional<String>.none) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.server(status) }
        return (data, status)
    }

    // MARK: - Owner

    struct SnapshotReceipt: Codable { var version: Int; var publishedAt: Date }

    /// Replaces the household's snapshot. The payload is already ciphertext.
    @discardableResult
    func publish(payload: String) async throws -> SnapshotReceipt {
        struct Body: Encodable { let payload: String }
        let (data, _) = try await send(try request("v1/snapshot", method: "POST", body: Body(payload: payload)))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SnapshotReceipt.self, from: data)
    }

    struct Invite: Codable { var code: String }

    func createInvite() async throws -> Invite {
        let (data, _) = try await send(try request("v1/viewers/invite", method: "POST", body: Optional<String>.none))
        return try JSONDecoder().decode(Invite.self, from: data)
    }

    struct Viewer: Codable, Identifiable {
        var id: String
        var label: String?
        var createdAt: Date
        var lastSeenAt: Date?
    }

    func listViewers() async throws -> [Viewer] {
        struct Response: Codable { var viewers: [Viewer] }
        let (data, _) = try await send(try request("v1/viewers", method: "GET"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).viewers
    }

    func revokeViewer(id: String) async throws {
        struct Body: Encodable { let id: String }
        _ = try await send(try request("v1/viewers/revoke", method: "POST", body: Body(id: id)))
    }

    struct StoredReport: Codable, Identifiable {
        var id: String
        var payload: String
        var snapshotVersion: Int?
        var createdAt: Date
        var viewerLabel: String?
    }

    func listReports() async throws -> [StoredReport] {
        struct Response: Codable { var reports: [StoredReport] }
        let (data, _) = try await send(try request("v1/reports", method: "GET"))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).reports
    }

    func acknowledgeReports(ids: [String]) async throws {
        struct Body: Encodable { let ids: [String] }
        _ = try await send(try request("v1/reports/ack", method: "POST", body: Body(ids: ids)))
    }

    // MARK: - Viewer

    struct StoredSnapshot: Codable { var payload: String; var version: Int; var publishedAt: Date }

    /// Nil when the owner has never published — a normal state for a phone that
    /// joined before the first sync, and one the UI should explain rather than
    /// present as a failure.
    func fetchSnapshot() async throws -> StoredSnapshot? {
        let (data, status) = try await send(try request("v1/viewer/snapshot", method: "GET"))
        guard status != 204, !data.isEmpty else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoredSnapshot.self, from: data)
    }

    func sendReport(payload: String, snapshotVersion: Int?) async throws {
        struct Body: Encodable { let payload: String; let snapshotVersion: Int? }
        _ = try await send(try request("v1/viewer/reports", method: "POST", body: Body(payload: payload, snapshotVersion: snapshotVersion)))
    }

    // MARK: - Joining

    /// Redeems an invite. Unauthenticated — the code is the credential — so this
    /// is a static call rather than a method on a configured client.
    static func redeem(invite: ViewerInvite, label: String) async throws -> String {
        guard let baseURL = URL(string: invite.url) else { throw Failure.notConfigured }

        struct Body: Encodable { let code: String; let label: String }
        struct Response: Codable { let token: String }

        var request = URLRequest(url: baseURL.appendingPathComponent("v1/viewers/redeem"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(code: invite.code, label: label))

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 { throw Failure.inviteRejected }
        guard (200..<300).contains(status) else { throw Failure.server(status) }

        return try JSONDecoder().decode(Response.self, from: data).token
    }
}
