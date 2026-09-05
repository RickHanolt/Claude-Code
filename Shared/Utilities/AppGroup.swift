import Foundation

/// Shared container so the Share Extension and the main app read/write the
/// same SwiftData store and the same pending-email-events queue.
///
/// IMPORTANT: this identifier must match the `com.apple.security.application-groups`
/// entry generated from `project.yml` for both targets, AND must be
/// registered as an "App Group" identifier in the Apple Developer portal
/// (developer.apple.com/account/resources/identifiers/list/application-group)
/// and attached to both App IDs' capabilities before either target can be
/// signed for a real device or TestFlight. If you change the bundle
/// identifiers, update the group id in `project.yml` (both targets) and here
/// together.
enum AppGroup {
    static let identifier = "group.com.rickhanolt.schoolsync"

    static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            fatalError("App Group '\(identifier)' is not configured for this target's entitlements.")
        }
        return url
    }

    /// Defaults shared with the share extension, for preferences both
    /// processes need to agree on.
    ///
    /// Optional rather than force-unwrapped: `@AppStorage` falls back to
    /// `.standard` when handed nil, so a misconfigured entitlement costs a
    /// setting that doesn't cross into the extension rather than a crash.
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    static var sharedModelStoreURL: URL {
        containerURL.appendingPathComponent("SchoolSync.sqlite")
    }

    /// Where the share extension queues parsed email events for the main app
    /// to pick up on its next sync (`EventStore.ingestPendingEmailEvents`).
    static var pendingEmailEventsURL: URL {
        containerURL.appendingPathComponent("PendingEmailEvents.json")
    }

    /// Where the share extension queues the full original email (subject +
    /// body) for the main app to store, independent of whether any event
    /// candidates were found/confirmed for it — this is what backs the
    /// Emails tab.
    static var pendingForwardedEmailsURL: URL {
        containerURL.appendingPathComponent("PendingForwardedEmails.json")
    }
}
