import SwiftUI

/// Whether the app follows the phone's appearance or pins its own.
///
/// Stored in the App Group's defaults rather than the app's own, so the share
/// extension can honour the same choice. A separate process is still a
/// separate process — a share sheet that comes up dark over an app pinned to
/// light is exactly the kind of seam that reads as a bug.
enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// `nil` means "don't express a preference", which is what makes System
    /// genuinely follow the phone rather than guess at it once on launch.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    static let storageKey = "appearance"

    /// Resolves whatever is in defaults, tolerating a value written by a
    /// future version that adds a case this build doesn't know.
    static func resolve(_ rawValue: String) -> AppearanceSetting {
        AppearanceSetting(rawValue: rawValue) ?? .system
    }
}
