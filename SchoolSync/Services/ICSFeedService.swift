import Foundation

enum ICSFeedError: Error {
    case badResponse
    case decodingFailed
}

struct ICSFeedService {
    func fetchEvents(from url: URL, kidID: UUID, schoolID: UUID) async throws -> [SchoolEventDTO] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ICSFeedError.badResponse
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ICSFeedError.decodingFailed
        }
        return ICSParser.parse(text, kidID: kidID, schoolID: schoolID)
    }
}
