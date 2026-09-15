import Foundation
import CryptoKit

/// Encrypts what leaves the phone.
///
/// Snapshots and reports are sealed here with a household key that travels
/// between devices in a QR code and never reaches the backend. The Worker
/// stores bytes it cannot read.
///
/// Deliberately boring. AES-GCM through CryptoKit, one symmetric key, the
/// library's own combined representation so nonce handling isn't something this
/// file gets to be creative about. Cryptography is the easiest thing here to
/// get subtly and invisibly wrong, and the correct amount of invention is none.
///
/// The key is cheap to lose on purpose: a snapshot is derived data, so losing
/// every copy of the key costs a republish and a re-scan, not a calendar.
enum HouseholdCrypto {
    enum Failure: LocalizedError {
        case badKey
        case cannotDecrypt

        var errorDescription: String? {
            switch self {
            case .badKey:
                "that code isn't valid."
            case .cannotDecrypt:
                // Loud on purpose. A viewer holding the wrong key must say so,
                // not quietly show an empty day — an empty Morning Mode reads
                // as "nothing unusual", which is the most dangerous thing this
                // app can say when it actually means "I can't read this".
                "couldn't read the update — this phone's code may no longer match."
            }
        }
    }

    static func newKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Base64url so a key can sit inside a QR payload without escaping.
    static func encode(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ string: String) throws -> SymmetricKey {
        var padded = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded += "=" }

        guard let data = Data(base64Encoded: padded), data.count == 32 else {
            throw Failure.badKey
        }
        return SymmetricKey(data: data)
    }

    static func seal<T: Encodable>(_ value: T, with key: SymmetricKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sealed = try AES.GCM.seal(encoder.encode(value), using: key)

        guard let combined = sealed.combined else { throw Failure.cannotDecrypt }
        return combined.base64EncodedString()
    }

    static func open<T: Decodable>(_ type: T.Type, from payload: String, with key: SymmetricKey) throws -> T {
        guard let data = Data(base64Encoded: payload) else { throw Failure.cannotDecrypt }

        let box: AES.GCM.SealedBox
        let plaintext: Data
        do {
            box = try AES.GCM.SealedBox(combined: data)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            // Every failure below the surface — wrong key, truncated payload,
            // tampered ciphertext — is the same thing to the person holding the
            // phone, and distinguishing them here would only leak detail.
            throw Failure.cannotDecrypt
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: plaintext)
    }
}
