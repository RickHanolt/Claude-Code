import Foundation

/// When the app is allowed to sync on its own.
///
/// The Sync Now button was the only way anything refreshed, which put a manual
/// step in front of the one question this app exists to answer. Opening the app
/// should be enough.
///
/// Throttled rather than run on every appearance: a sync fetches every school's
/// feed and asks the backend to extract anything outstanding, and doing that
/// each time the app is brought forward — which on a school morning is several
/// times in ten minutes — is a lot of traffic to answer a question whose answer
/// changed at most once overnight.
enum AutoSync {
    /// Long enough that flicking between apps costs nothing, short enough that
    /// a newsletter forwarded at breakfast is on the calendar before the school
    /// run.
    static let minimumInterval: TimeInterval = 15 * 60

    static let storageKey = "lastAutoSyncAt"

    private static var defaults: UserDefaults { AppGroup.sharedDefaults ?? .standard }

    static func shouldRun(now: Date = .now) -> Bool {
        let last = defaults.double(forKey: storageKey)
        // An absent key reads as 0 — the epoch — which is correctly "ages ago"
        // and makes the first launch sync immediately.
        return now.timeIntervalSince1970 - last >= minimumInterval
    }

    /// Recorded whether or not the sync found anything, and whether or not it
    /// hit errors. A backend that's down shouldn't be retried on a loop every
    /// time the app is foregrounded; its failure is already reported in the
    /// sync result, and waiting out the interval is the cheaper way to be wrong.
    static func markRun(at date: Date = .now) {
        defaults.set(date.timeIntervalSince1970, forKey: storageKey)
    }
}
