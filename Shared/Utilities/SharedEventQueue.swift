import Foundation

/// A simple JSON-file queue in the App Group container. The share extension
/// appends confirmed email events here (it can't easily open the main app's
/// SwiftData `ModelContainer` for writes while also driving UI); the main
/// app drains it into the real store on the next sync via
/// `EventStore.ingestPendingEmailEvents`.
enum SharedEventQueue {
    static func append(_ dtos: [SchoolEventDTO]) throws {
        guard !dtos.isEmpty else { return }
        var existing = try readAll()
        existing.append(contentsOf: dtos)
        let data = try JSONEncoder().encode(existing)
        try data.write(to: AppGroup.pendingEmailEventsURL, options: .atomic)
    }

    static func readAll() throws -> [SchoolEventDTO] {
        let url = AppGroup.pendingEmailEventsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        if data.isEmpty { return [] }
        return try JSONDecoder().decode([SchoolEventDTO].self, from: data)
    }

    static func clear() throws {
        let url = AppGroup.pendingEmailEventsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
