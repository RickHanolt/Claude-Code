import Foundation

/// A JSON-file queue in the App Group container, mirroring
/// `SharedEventQueue` — the share extension appends the full original email
/// here on save; the main app drains it into the real store on the next
/// sync via `EventStore.ingestPendingForwardedEmails`.
enum SharedEmailQueue {
    static func append(_ dtos: [ForwardedEmailDTO]) throws {
        guard !dtos.isEmpty else { return }
        var existing = try readAll()
        existing.append(contentsOf: dtos)
        let data = try JSONEncoder().encode(existing)
        try data.write(to: AppGroup.pendingForwardedEmailsURL, options: .atomic)
    }

    static func readAll() throws -> [ForwardedEmailDTO] {
        let url = AppGroup.pendingForwardedEmailsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([ForwardedEmailDTO].self, from: data)
    }

    static func clear() throws {
        let url = AppGroup.pendingForwardedEmailsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
