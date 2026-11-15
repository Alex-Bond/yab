import CryptoKit
import Foundation

/// A Mac-issued challenge for one exact action. The signing key is enrolled
/// locally on that Mac; a key arriving in a chat or a reply is never trusted.
/// Transport and the Mac's live DOM revalidation are required before enabling
/// this protocol. Verifying alone grants no agent permission.
public struct TaskApproval: Codable, Hashable, Sendable {
    public struct Action: Codable, Hashable, Sendable {
        public var account: String
        public var mac: String
        public var device: String
        public var task: String
        public var session: String
        public var tab: String
        public var reference: String
        public var url: String
        public var kind: String
        public var title: String
        public var subtitle: String
        public var facts: [[String]]
        public var button: String

        public init(account: String, mac: String, device: String, task: String, session: String, tab: String,
                    reference: String, url: String, kind: String, title: String, subtitle: String,
                    facts: [[String]], button: String) {
            self.account = account; self.mac = mac; self.device = device; self.task = task
            self.session = session; self.tab = tab; self.reference = reference; self.url = url
            self.kind = kind; self.title = title; self.subtitle = subtitle; self.facts = facts; self.button = button
        }
    }

    public var action: Action
    public var keyID: String
    public var nonce: String
    public var issued: Int64
    public var expires: Int64

    public init(action: Action, keyID: String, nonce: String, issued: Int64, expires: Int64) {
        self.action = action; self.keyID = keyID; self.nonce = nonce; self.issued = issued; self.expires = expires
    }

    public enum Failure: Error, Equatable {
        case invalid, expired, changed, untrustedKey, signature
    }

    public static func keyID(_ key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).map { String(format: "%02x", $0) }.joined()
    }

    /// Canonical JSON retains array and string boundaries, unlike a digest
    /// built by joining facts with tabs and newlines.
    public func digest() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = Data("yab task approval v2\n".utf8)
        bytes.append(try encoder.encode(self))
        return Data(SHA256.hash(data: bytes))
    }

    public func validate(at now: Int64) throws {
        let identities = [action.account, action.mac, action.device, action.task, action.session, action.tab, action.reference, keyID]
        guard identities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 200 }), UUID(uuidString: nonce) != nil,
              ["pay", "post", "cancel"].contains(action.kind), OpenOnMac.url(action.url) != nil,
              issued >= 0, issued <= now + 30, expires > issued, expires - issued <= 300 else { throw Failure.invalid }
        guard now < expires else { throw Failure.expired }
    }

    /// `current` must be read again from the live Mac permit and DOM, not the
    /// reply's fields. The caller consumes a durable nonce before allowing the
    /// exact pending permit; no other session or action can use this signature.
    public func verify(digest signedDigest: Data, signature: Data, trustedKey: P256.Signing.PublicKey,
                       current: Action, at now: Int64) throws {
        try validate(at: now)
        guard action == current else { throw Failure.changed }
        guard keyID == Self.keyID(trustedKey) else { throw Failure.untrustedKey }
        let expected = try digest()
        guard signedDigest == expected, let signed = try? P256.Signing.ECDSASignature(rawRepresentation: signature),
              trustedKey.isValidSignature(signed, for: expected) else { throw Failure.signature }
    }
}
