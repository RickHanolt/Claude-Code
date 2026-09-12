import Foundation

/// Whether mail from a sender whose kid is already known is filed without
/// anyone tapping through the review screen.
///
/// Read from plain `UserDefaults` rather than `@AppStorage` because the code
/// that needs it is a sync coordinator, not a view.
///
/// Defaults to on. The review screen was never the point — it exists because
/// the backend has no idea which child an email is about, and a learned sender
/// route answers that question permanently. The first mail from any address is
/// still reviewed by hand, which is both how a route gets learned and the
/// reason this can be on by default: nothing unfamiliar writes to a calendar
/// unsupervised.
enum AutoAcceptSetting {
    static let storageKey = "autoAcceptRoutedMail"

    static var isEnabled: Bool {
        let defaults = AppGroup.sharedDefaults ?? .standard
        // `bool(forKey:)` returns false for an absent key, which would make the
        // default off rather than unset. Check for the key itself.
        guard defaults.object(forKey: storageKey) != nil else { return true }
        return defaults.bool(forKey: storageKey)
    }
}
