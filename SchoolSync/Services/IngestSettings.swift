import Foundation

/// Configuration for the optional auto-forward backend (see
/// INGEST_BACKEND.md) — unset by default, meaning the feature is entirely
/// inactive and the app behaves exactly as it did before (on-device only).
/// The base URL isn't sensitive and lives in UserDefaults; the API key is
/// treated as a secret and lives in the Keychain.
enum IngestSettings {
    private static let baseURLKey = "ingest.baseURL"
    private static let apiKeyAccount = "apiKey"

    static var baseURL: URL? {
        get {
            guard let string = UserDefaults.standard.string(forKey: baseURLKey), !string.isEmpty else { return nil }
            return URL(string: string)
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: baseURLKey)
        }
    }

    static var apiKey: String? {
        get { Keychain.get(forAccount: apiKeyAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, forAccount: apiKeyAccount)
            } else {
                Keychain.delete(forAccount: apiKeyAccount)
            }
        }
    }

    /// Both a base URL and an API key are required for the feature to do
    /// anything — `SyncCoordinator` checks this before ever making a
    /// network request.
    static var isConfigured: Bool {
        baseURL != nil && apiKey?.isEmpty == false
    }
}
