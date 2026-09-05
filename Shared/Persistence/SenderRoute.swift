import Foundation
import SwiftData

/// Which kid a given sender's mail has turned out to be about.
///
/// The backend cannot answer this — it stores mail per household and has no
/// column naming a child anywhere in its schema, which is the property that
/// makes forwarding school mail to a server acceptable in the first place. So
/// the answer lives here, on the phone, and is learned rather than configured:
/// each time an email is assigned, the choice is remembered against its sender.
///
/// Last write wins, deliberately. A sender that consistently means one kid is
/// the common case and gets the obvious behaviour; a shared address that
/// sometimes means the other simply reflects whatever was chosen most recently.
/// The alternative — tracking that a sender has become ambiguous and refusing
/// to guess — is more correct in the abstract and worse to live with, because
/// "it used to remember and now it doesn't" has no visible cause. Every
/// suggestion is shown on screen before anything is saved, so a wrong guess
/// costs one tap.
@Model
final class SenderRoute {
    /// Normalized address, so "News@SMA.org" and "news@sma.org " are one route.
    @Attribute(.unique) var sender: String

    var kidID: UUID
    var schoolID: UUID
    var updatedAt: Date

    init(sender: String, kidID: UUID, schoolID: UUID, updatedAt: Date = .now) {
        self.sender = sender
        self.kidID = kidID
        self.schoolID = schoolID
        self.updatedAt = updatedAt
    }

    /// Lowercased, trimmed, and unwrapped from a display-name form.
    ///
    /// The Worker stores `parsed.from?.address`, which is already bare, but a
    /// mailer that hands over "SMA News <news@sma.org>" would otherwise create
    /// a route that never matches the same sender again.
    static func normalize(_ address: String?) -> String? {
        guard var value = address?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return nil }

        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
            value = String(value[value.index(after: open)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value.isEmpty ? nil : value
    }
}
