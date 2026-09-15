import SwiftUI

/// Whether this phone is reading someone else's published schedule.
///
/// Passed down the environment rather than read from `ViewerSettings` inside
/// each screen. Two reasons: a view body that reads a global has no way to
/// know when that global changes, so the screen would keep whatever it saw
/// first; and one decision made at the root can't disagree with itself the way
/// six independent checks eventually will.
private struct IsViewerKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True on a viewing phone. Screens use it to hide what a viewer can't do —
    /// never to hide what a viewer needs to know.
    var isViewer: Bool {
        get { self[IsViewerKey.self] }
        set { self[IsViewerKey.self] = newValue }
    }
}

/// How long ago the owner published, in words.
///
/// Shown rather than hidden, and always — not only when it's old. A viewer has
/// no other way to tell a quiet morning from a phone that stopped updating on
/// Tuesday, and those two look identical on every screen in this app.
enum SnapshotFreshness {
    static func describe(_ publishedAt: Date?) -> String {
        guard let publishedAt else { return "Waiting for the first update." }

        let elapsed = Date.now.timeIntervalSince(publishedAt)
        if elapsed < 90 { return "Updated just now." }

        let relative = publishedAt.formatted(.relative(presentation: .named))
        return "Updated \(relative)."
    }

    /// Past this, the line stops being a detail and starts being a warning.
    /// A day and a half spans a normal overnight gap plus a morning, so a phone
    /// that simply wasn't opened yesterday evening doesn't cry wolf.
    static func isStale(_ publishedAt: Date?) -> Bool {
        guard let publishedAt else { return true }
        return Date.now.timeIntervalSince(publishedAt) > 36 * 60 * 60
    }
}
