import Foundation
import CryptoKit

/// Which side of viewer mode this phone is on.
///
/// Decided by how the app was first set up, not by a switch anyone chooses.
/// A phone that scanned an invite is a viewer, forever, until it leaves.
enum AppRole {
    /// Forwards mail, reviews it, owns the store, publishes snapshots.
    case owner
    /// Reads a published snapshot. Can report, cannot edit.
    case viewer
    /// Freshly installed, hasn't been told which it is.
    case unconfigured
}

/// Credentials and membership for viewer mode.
///
/// The household key is a secret and lives in the Keychain alongside the ingest
/// API key. The backend URL isn't, and lives in UserDefaults — same split the
/// rest of the app already uses.
enum ViewerSettings {
    private static let viewerTokenAccount = "viewerToken"
    private static let householdKeyAccount = "householdKey"
    private static let viewerBaseURLKey = "viewer.baseURL"

    /// Present only on a viewing phone.
    static var viewerToken: String? {
        get { Keychain.get(forAccount: viewerTokenAccount) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.set(newValue, forAccount: viewerTokenAccount)
            } else {
                Keychain.delete(forAccount: viewerTokenAccount)
            }
        }
    }

    /// The backend a viewer talks to. An owner already has this in
    /// `IngestSettings`; a viewer gets it from the QR code and never sees it.
    static var viewerBaseURL: URL? {
        get {
            guard let string = UserDefaults.standard.string(forKey: viewerBaseURLKey), !string.isEmpty else { return nil }
            return URL(string: string)
        }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: viewerBaseURLKey) }
    }

    /// Shared by every phone in the household. Generated once by the owner.
    static var householdKey: SymmetricKey? {
        get {
            guard let encoded = Keychain.get(forAccount: householdKeyAccount) else { return nil }
            return try? HouseholdCrypto.decode(encoded)
        }
        set {
            if let newValue {
                Keychain.set(HouseholdCrypto.encode(newValue), forAccount: householdKeyAccount)
            } else {
                Keychain.delete(forAccount: householdKeyAccount)
            }
        }
    }

    /// Created on first publish and then left alone. Rotating it would strand
    /// every viewer mid-week with no way to tell them why.
    static func householdKeyCreatingIfNeeded() -> SymmetricKey {
        if let existing = householdKey { return existing }
        let key = HouseholdCrypto.newKey()
        householdKey = key
        return key
    }

    /// Viewer first: a phone that has both a viewer token and ingest
    /// credentials is a configuration accident, and reading it as a viewer is
    /// the safer half — a viewer can't write to anyone's calendar.
    static var role: AppRole {
        if viewerToken?.isEmpty == false, viewerBaseURL != nil { return .viewer }
        if IngestSettings.isConfigured { return .owner }
        return .unconfigured
    }

    private static let hasViewersKey = "viewer.hasViewers"

    /// Whether this household has anyone reading it.
    ///
    /// Cached rather than asked, because it gates publishing on every sync and
    /// a network round-trip to learn "nobody" would be a poor trade. Set when
    /// an invite is created, cleared when the last viewer is revoked — so the
    /// worst a stale value costs is one unnecessary upload or one late first
    /// snapshot, both of which the next sync corrects.
    static var hasViewers: Bool {
        get { UserDefaults.standard.bool(forKey: hasViewersKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasViewersKey) }
    }

    // MARK: - What a viewer is currently showing

    private static let snapshotVersionKey = "viewer.snapshotVersion"

    /// Stored as a plain interval, and the key is public, so screens can watch
    /// it with `@AppStorage` and redraw the moment a refresh lands. Read once
    /// into `@State` instead and the "updated X ago" line freezes at whatever
    /// it said when the screen first appeared — which is precisely the lie the
    /// line exists to prevent.
    static let snapshotPublishedAtKey = "viewer.snapshotPublishedAt"

    /// Recorded so a report can name exactly which version its author was
    /// looking at, and so the screen can say how old that version is.
    static var snapshotVersion: Int? {
        get {
            let stored = UserDefaults.standard.integer(forKey: snapshotVersionKey)
            return stored == 0 ? nil : stored
        }
        set { UserDefaults.standard.set(newValue ?? 0, forKey: snapshotVersionKey) }
    }

    /// When the *owner* published, not when this phone fetched. Those differ
    /// whenever the owner's phone hasn't been opened, which is exactly the case
    /// a viewer needs to be warned about.
    static var snapshotPublishedAt: Date? {
        get { date(fromStoredInterval: UserDefaults.standard.double(forKey: snapshotPublishedAtKey)) }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: snapshotPublishedAtKey) }
    }

    /// Zero means "never published" rather than 1970 — the sentinel a
    /// `@AppStorage(Double)` default gives us for free.
    static func date(fromStoredInterval interval: Double) -> Date? {
        interval == 0 ? nil : Date(timeIntervalSince1970: interval)
    }

    // MARK: - First run

    /// Whether anyone has told this install which kind of phone it is.
    ///
    /// Separate from `role` because an owner is `.unconfigured` right up until
    /// they've entered backend credentials, and most owners never will — the
    /// app works perfectly well on its own. So `role` can't answer "is this a
    /// fresh install?", and asking someone who has been using the app for weeks
    /// whether they'd like to set it up would be alarming.
    static let hasChosenRoleKey = "viewer.hasChosenRole"

    static var hasChosenRole: Bool {
        get { UserDefaults.standard.bool(forKey: hasChosenRoleKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasChosenRoleKey) }
    }

    /// Forgets every credential this phone held as a viewer.
    ///
    /// The store it was mirroring is wiped separately, by the caller, because
    /// leaving without clearing it would leave a phone showing a household's
    /// schedule forever with no way left to update or correct it.
    static func leaveHousehold() {
        snapshotVersion = nil
        snapshotPublishedAt = nil
        viewerToken = nil
        viewerBaseURL = nil
        householdKey = nil
        hasChosenRole = false
    }
}

/// What a QR code carries: where to talk, the one-time code to redeem, and the
/// key to read what comes back.
///
/// Compact field names because every character is another module in the QR, and
/// a code that needs a steady hand and good light is a code a grandparent
/// cannot scan.
struct ViewerInvite: Codable {
    var url: String
    var code: String
    var key: String

    enum CodingKeys: String, CodingKey {
        case url = "u"
        case code = "c"
        case key = "k"
    }

    var encoded: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(_ scanned: String) -> ViewerInvite? {
        guard let data = scanned.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ViewerInvite.self, from: data)
    }
}
