import Foundation

/// Senders whose mail always needs a person to say which kid it's for.
///
/// Sender routing assumes an address belongs to one child, which holds for a
/// school that only one of them attends and fails completely for the address
/// you forward things from yourself. A photographed permission slip or a PDF
/// could be for either kid, and the routing learned from the last one you sent
/// would file the next one silently and confidently wrong.
///
/// Stored as a plain list in the App Group's defaults rather than as a model
/// property. It's a small set of strings the user maintains by hand, it needs
/// no migration, and keeping it out of SwiftData means an address can be
/// exempted before any mail from it has ever arrived.
enum AlwaysAskSenders {
    static let storageKey = "alwaysAskSenders"

    private static var defaults: UserDefaults { AppGroup.sharedDefaults ?? .standard }

    /// Normalized on the way in and out, so an address typed with different
    /// capitalization than the one a mail server reports still matches.
    static var all: [String] {
        (defaults.stringArray(forKey: storageKey) ?? []).sorted()
    }

    static func contains(_ address: String?) -> Bool {
        guard let normalized = SenderRoute.normalize(address) else { return false }
        return all.contains(normalized)
    }

    /// Returns false when the address is unusable or already listed, so a
    /// caller can tell the user nothing happened rather than appearing to
    /// accept a typo.
    @discardableResult
    static func add(_ address: String?) -> Bool {
        guard let normalized = SenderRoute.normalize(address) else { return false }
        var current = Set(all)
        guard current.insert(normalized).inserted else { return false }
        defaults.set(Array(current), forKey: storageKey)
        return true
    }

    static func remove(_ address: String) {
        guard let normalized = SenderRoute.normalize(address) else { return }
        defaults.set(all.filter { $0 != normalized }, forKey: storageKey)
    }

    static func setAlwaysAsk(_ isOn: Bool, for address: String) {
        if isOn { add(address) } else { remove(address) }
    }
}
