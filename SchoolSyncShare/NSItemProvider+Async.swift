import Foundation

extension NSItemProvider {
    /// `loadItem(forTypeIdentifier:)` is closure-based only; this bridges it
    /// to async/await for use in the share extension's loading flow.
    func loadItemAsync(forTypeIdentifier typeIdentifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }
}
