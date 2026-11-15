import CommonCrypto
import CryptoKit
import Foundation

// What the server holds of a record: a name it can't read and a box it can't
// open. One random key per account, made on the first device and never sent
// to the server; from it, one key seals records and another hides their
// names, so the server sees neither "bookmark" nor the address in it.

public struct Seal: Sendable {
    public let key: SymmetricKey
    private let records: SymmetricKey
    private let names: SymmetricKey

    public init(key: SymmetricKey) {
        self.key = key
        records = Seal.derive(key, "yab sync records v1")
        names = Seal.derive(key, "yab sync names v1")
    }

    /// A new account's key.
    public static func make() -> Seal { Seal(key: SymmetricKey(size: .bits256)) }

    public init?(raw: Data) {
        guard raw.count == 32 else { return nil }
        self.init(key: SymmetricKey(data: raw))
    }

    public var raw: Data { key.withUnsafeBytes { Data($0) } }

    /// The name the server files a record under: the same on every device,
    /// meaningless without the key.
    public func name(_ key: Record.Key) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(key.collection)\u{0}\(key.id)".utf8), using: names)
        return Data(mac).base64URL
    }

    /// The record, sealed. The name goes in as associated data, so a box
    /// moved under another record's name doesn't open.
    public func seal(_ record: Record) throws -> Data {
        let plain = try JSONEncoder().encode(record)
        let box = try AES.GCM.seal(plain, using: records, authenticating: Data(name(record.key).utf8))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    public func open(_ sealed: Data, name: String) throws -> Record {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plain = try AES.GCM.open(box, using: records, authenticating: Data(name.utf8))
        let record = try JSONDecoder().decode(Record.self, from: plain)
        guard self.name(record.key) == name else { throw CryptoKitError.authenticationFailure }
        return record
    }

    static func derive(_ key: SymmetricKey, _ info: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(info.utf8), outputByteCount: 32)
    }

    // MARK: Secrets

    /// A field that stays sealed on the device too: a password, a card's
    /// number. The journal keeps records as they are, in a file anyone
    /// with the disk can read; a secret in it is this box, opened only by
    /// what holds the key, which lives in the keychain. Its record's key
    /// goes in as associated data, so a box moved to another record
    /// doesn't open.
    public func hide(_ plain: Data, in key: Record.Key) throws -> String {
        let box = try AES.GCM.seal(plain, using: Seal.derive(self.key, "yab sync secrets v1"), authenticating: Data(key.description.utf8))
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return combined.base64EncodedString()
    }

    public func reveal(_ text: String, in key: Record.Key) -> Data? {
        guard let data = Data(base64Encoded: text), let box = try? AES.GCM.SealedBox(combined: data) else { return nil }
        return try? AES.GCM.open(box, using: Seal.derive(self.key, "yab sync secrets v1"), authenticating: Data(key.description.utf8))
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - The account

public extension Seal {
    /// The account's address on the server: derived from the key, so a
    /// device that has the key knows where to go and nothing else does.
    var account: String {
        Data(Seal.derive(key, "yab sync account v1", bytes: 16).withUnsafeBytes { Data($0) }).base64URL
    }

    /// What proves to the server that a device holds the key. The server
    /// keeps its SHA-256 and can work out nothing else from it.
    var secret: String {
        Data(Seal.derive(key, "yab sync auth v1").withUnsafeBytes { Data($0) }).base64URL
    }

    /// The key written out to be kept somewhere safe: base32 in groups of
    /// four, with a check group at the end so a mistyped one is caught.
    var recovery: String {
        let check = Data(SHA256.hash(data: raw)).prefix(2)
        let text = Base32.encode(raw + check)
        return stride(from: 0, to: text.count, by: 4).map { i in
            let start = text.index(text.startIndex, offsetBy: i)
            return String(text[start..<(text.index(start, offsetBy: 4, limitedBy: text.endIndex) ?? text.endIndex)])
        }.joined(separator: "-")
    }

    /// A Recovery Key typed back in, spaces, dashes and case ignored, and
    /// the usual confusions (0 for O, 1 for I, 8 for B) forgiven.
    init?(recovery text: String) {
        guard let data = Base32.decode(text), data.count == 34 else { return nil }
        let raw = data.prefix(32), check = data.suffix(2)
        guard Data(SHA256.hash(data: raw)).prefix(2) == check else { return nil }
        self.init(raw: Data(raw))
    }

    fileprivate static func derive(_ key: SymmetricKey, _ info: String, bytes: Int) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: key, info: Data(info.utf8), outputByteCount: bytes)
    }
}

// MARK: - Joining by a code

/// A new device asking to be let in: it shows `code`, someone types it on a
/// device already in the account, which seals the key to `publicKey`.
///
/// The server sees the box name and the posted key, never the code. Both
/// come from a slow stretch of the code (`Stretch`), so a server, or anyone
/// reading its storage, can't try every code within the box's ten minutes,
/// and the posted key carries a tag only the code makes: a key swapped in
/// on the way is refused before anything is sealed to it.
public struct Joining: Sendable {
    public let code: String
    private let secret: Curve25519.KeyAgreement.PrivateKey

    public init(code: String? = nil) {
        self.code = code ?? Joining.makeCode()
        secret = Curve25519.KeyAgreement.PrivateKey()
    }

    public var publicKey: Data { secret.publicKey.rawRepresentation }

    /// What goes up as "pub": the key and its tag.
    public var posted: String { Joining.posted(publicKey, code: code) }

    static func posted(_ publicKey: Data, code: String) -> String {
        (publicKey + Joining.tag(publicKey, code: code)).base64EncodedString()
    }

    /// The key in what a device posted under `code`, if its tag says it was
    /// posted by one that knows the code. Nil for a bare key (an older Yab,
    /// or a key swapped in) and anything else.
    public static func verified(_ posted: String?, code: String) -> Data? {
        guard let data = posted.flatMap({ Data(base64Encoded: $0) }), data.count == 64 else { return nil }
        let key = data.prefix(32), tag = data.suffix(32)
        let mac = Stretch.of(code).mac
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: Data("yab sync pub v2".utf8) + key, using: mac) else { return nil }
        return Data(key)
    }

    static func tag(_ publicKey: Data, code: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("yab sync pub v2".utf8) + publicKey, using: Stretch.of(code).mac))
    }

    /// Where the code is kept on the server: a name made from it, never the code.
    public static func box(_ code: String) -> String { Stretch.of(code).box }

    public var box: String { Joining.box(code) }

    /// On the device already in: the key, sealed so only the device that
    /// showed the code can open it.
    public static func seal(_ seal: Seal, to publicKey: Data, code: String) throws -> Data {
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let mine = Curve25519.KeyAgreement.PrivateKey()
        let shared = try mine.sharedSecretFromKeyAgreement(with: theirs)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Stretch.of(code).salt, sharedInfo: Data("yab sync join v2".utf8), outputByteCount: 32)
        let box = try AES.GCM.seal(seal.raw, using: key)
        guard let combined = box.combined else { throw CryptoKitError.incorrectParameterSize }
        return mine.publicKey.rawRepresentation + combined
    }

    /// On the new device: the key out of what the other sealed.
    public func open(_ envelope: Data) throws -> Seal {
        guard envelope.count > 32 else { throw CryptoKitError.incorrectParameterSize }
        let theirs = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: envelope.prefix(32))
        let shared = try secret.sharedSecretFromKeyAgreement(with: theirs)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Stretch.of(code).salt, sharedInfo: Data("yab sync join v2".utf8), outputByteCount: 32)
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.dropFirst(32)), using: key)
        guard let seal = Seal(raw: raw) else { throw CryptoKitError.incorrectParameterSize }
        return seal
    }

    /// Eight letters and digits, none that read as another (no 0/O, 1/I/L).
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")

    static func makeCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<8).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
        return String(chars[0..<4]) + "-" + String(chars[4..<8])
    }

    static func normalize(_ code: String) -> String {
        code.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// The code made slow to guess. Eight characters from 31 are about 2^40
/// codes: a plain hash of them falls to a laptop in an hour. Stretched by
/// PBKDF2 a guess costs as much as one on the device does (a fifth of a
/// second here), so trying them all within a box's ten minutes would take
/// tens of thousands of GPUs. Worked out once per code and kept.
struct Stretch: Sendable {
    let box: String
    let mac: SymmetricKey
    let salt: Data

    static let rounds: UInt32 = 300_000

    static func of(_ code: String) -> Stretch {
        let normal = Joining.normalize(code)
        lock.lock()
        if let kept = kept[normal] { lock.unlock(); return kept }
        lock.unlock()
        let master = SymmetricKey(data: pbkdf2(Data(normal.utf8), salt: Data("yab sync pairing v2".utf8), rounds: rounds))
        let derive = { (info: String) in
            HKDF<SHA256>.deriveKey(inputKeyMaterial: master, info: Data(info.utf8), outputByteCount: 32).withUnsafeBytes { Data($0) }
        }
        let made = Stretch(box: derive("box").map { String(format: "%02x", $0) }.joined(),
                           mac: SymmetricKey(data: derive("pub")),
                           salt: derive("envelope"))
        lock.lock()
        if kept.count > 16 { kept.removeAll() }
        kept[normal] = made
        lock.unlock()
        return made
    }

    nonisolated(unsafe) private static var kept: [String: Stretch] = [:]
    private static let lock = NSLock()

    static func pbkdf2(_ password: Data, salt: Data, rounds: UInt32) -> Data {
        var out = Data(count: 32)
        let status = out.withUnsafeMutableBytes { outBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                         outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return out
    }
}

// MARK: - Base32

enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var out = "", buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func decode(_ text: String) -> Data? {
        var out = Data(), buffer = 0, bits = 0
        for char in text.uppercased() {
            if char == " " || char == "-" || char == "\n" { continue }
            let c: Character = char == "0" ? "O" : char == "1" ? "I" : char == "8" ? "B" : char
            guard let value = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5) | value; bits += 5
            if bits >= 8 {
                out.append(UInt8((buffer >> (bits - 8)) & 255)); bits -= 8
            }
            buffer &= (1 << bits) - 1
        }
        return out
    }
}
