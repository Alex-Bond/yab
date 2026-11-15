import CryptoKit
import Foundation

// What a site's server sends a push subscription is encrypted to the keys
// Yab made for it (RFC 8291): a P-256 key pair and a 16-byte auth secret.
// The push service in between (WebPush.swift, sync-server/src/webpush.ts)
// only carries the bytes. Two content codings are out there: aes128gcm
// (RFC 8188), which everything current sends, and aesgcm, the drafts'
// one, with its salt and the server's key in headers, which older
// libraries still send and Chrome still takes.

enum WebPushCrypto {
    struct Keys {
        let privateKey: P256.KeyAgreement.PrivateKey
        let auth: Data

        /// The subscription's p256dh: the public key, uncompressed (65 bytes).
        var publicKey: Data { privateKey.publicKey.x963Representation }

        static func make() -> Keys {
            var auth = Data(count: 16)
            _ = auth.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
            return Keys(privateKey: P256.KeyAgreement.PrivateKey(), auth: auth)
        }
    }

    enum Failure: Error, Equatable {
        case short, header, key, record, padding, coding
    }

    /// The plain bytes of a message, by its Content-Encoding. `encryption`
    /// and `cryptoKey` are the aesgcm headers, as they came.
    static func open(_ body: Data, coding: String, encryption: String = "", cryptoKey: String = "", keys: Keys) throws -> Data {
        switch coding.lowercased() {
        case "aes128gcm": return try aes128gcm(body, keys: keys)
        case "aesgcm": return try aesgcm(body, encryption: encryption, cryptoKey: cryptoKey, keys: keys)
        default: throw Failure.coding
        }
    }

    // MARK: - aes128gcm (RFC 8188, RFC 8291)

    static func aes128gcm(_ body: Data, keys: Keys) throws -> Data {
        let bytes = [UInt8](body)
        // salt (16) | record size (4) | key id length (1) | key id: the server's public key.
        guard bytes.count >= 21 else { throw Failure.short }
        let salt = Data(bytes[0..<16])
        let size = Int(bytes[16]) << 24 | Int(bytes[17]) << 16 | Int(bytes[18]) << 8 | Int(bytes[19])
        let idLength = Int(bytes[20])
        guard size > 17, bytes.count >= 21 + idLength, idLength == 65 else { throw Failure.header }
        let serverKey = Data(bytes[21..<(21 + idLength)])
        let shared = try secret(serverKey, keys)
        let info = Data("WebPush: info".utf8) + [0] + keys.publicKey + serverKey
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: shared, salt: keys.auth, info: info, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm".utf8) + [0], outputByteCount: 16)
        let nonce = bytesOf(HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce".utf8) + [0], outputByteCount: 12))

        var out = Data()
        var at = 21 + idLength
        var sequence: UInt64 = 0
        while at < bytes.count {
            let end = min(at + size, bytes.count)
            let record = Data(bytes[at..<end])
            let last = end == bytes.count
            var plain = try openRecord(record, key: key, nonce: nonce, sequence: sequence)
            // Data, then 0x01 (more records follow) or 0x02 (the last), then zeros.
            while plain.last == 0 { plain.removeLast() }
            guard let delimiter = plain.popLast(), delimiter == (last ? 2 : 1) else { throw Failure.padding }
            out += plain
            at = end
            sequence += 1
        }
        return out
    }

    // MARK: - aesgcm (draft-ietf-webpush-encryption-04)

    static func aesgcm(_ body: Data, encryption: String, cryptoKey: String, keys: Keys) throws -> Data {
        guard let salt = param("salt", in: encryption).flatMap(Data.init(urlBase64:)), salt.count == 16,
              let serverKey = param("dh", in: cryptoKey).flatMap(Data.init(urlBase64:)), serverKey.count == 65
        else { throw Failure.header }
        let size = param("rs", in: encryption).flatMap(Int.init) ?? 4096
        guard size > 1 else { throw Failure.header }
        let shared = try secret(serverKey, keys)
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: shared, salt: keys.auth, info: Data("Content-Encoding: auth".utf8) + [0], outputByteCount: 32)
        var context = Data("P-256".utf8) + [0]
        context += [0, 65] + keys.publicKey + [0, 65] + serverKey
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aesgcm".utf8) + [0] + context, outputByteCount: 16)
        let nonce = bytesOf(HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce".utf8) + [0] + context, outputByteCount: 12))

        let bytes = [UInt8](body)
        var out = Data()
        var at = 0
        var sequence: UInt64 = 0
        // Each record is up to `rs` bytes of padded plaintext, and its tag.
        while at < bytes.count {
            let end = min(at + size + 16, bytes.count)
            let plain = [UInt8](try openRecord(Data(bytes[at..<end]), key: key, nonce: nonce, sequence: sequence))
            // A two-byte padding length, that many zeros, then the data.
            guard plain.count >= 2 else { throw Failure.padding }
            let padding = Int(plain[0]) << 8 | Int(plain[1])
            guard plain.count >= 2 + padding else { throw Failure.padding }
            out += Data(plain[(2 + padding)...])
            at = end
            sequence += 1
        }
        return out
    }

    // MARK: - shared

    private static func secret(_ serverKey: Data, _ keys: Keys) throws -> SymmetricKey {
        guard let server = try? P256.KeyAgreement.PublicKey(x963Representation: serverKey) else { throw Failure.key }
        let shared = try keys.privateKey.sharedSecretFromKeyAgreement(with: server)
        return SymmetricKey(data: shared.withUnsafeBytes { Data($0) })
    }

    private static func openRecord(_ record: Data, key: SymmetricKey, nonce: [UInt8], sequence: UInt64) throws -> Data {
        guard record.count > 16 else { throw Failure.record }
        var iv = nonce
        // The record's number goes into the nonce's last six bytes.
        for i in 0..<6 { iv[11 - i] ^= UInt8(truncatingIfNeeded: sequence >> (8 * UInt64(i))) }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: record.dropLast(16), tag: record.suffix(16))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw Failure.record
        }
    }

    private static func bytesOf(_ key: SymmetricKey) -> [UInt8] {
        key.withUnsafeBytes { [UInt8]($0) }
    }

    /// `name=value` out of a header like "salt=…; rs=4096" or
    /// "dh=…;p256ecdsa=…", comma separated lists included.
    static func param(_ name: String, in header: String) -> String? {
        for part in header.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == name { return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }
}

extension Data {
    /// URL-safe base64, padded or not, as Web Push writes keys.
    init?(urlBase64 text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }

    var urlBase64: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
