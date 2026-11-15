import CryptoKit
import Foundation
import Testing
@testable import Fast

// Web Push (WebPush.swift, WebPushCrypto.swift): what a site's server sends
// opens with the subscription's keys, in both codings servers use, and
// nothing else opens.
struct WebPushTests {
    /// RFC 8291, Appendix A, byte for byte.
    @Test func opensTheRFCsExample() throws {
        let keys = WebPushCrypto.Keys(
            privateKey: try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(urlBase64: "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94")!),
            auth: Data(urlBase64: "BTBZMqHH6r4Tts7J_aSIgg")!)
        #expect(keys.publicKey.urlBase64 == "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")
        let message = Data(urlBase64: "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")!
        let plain = try WebPushCrypto.open(message, coding: "aes128gcm", keys: keys)
        #expect(String(data: plain, encoding: .utf8) == "When I grow up, I want to be a watermelon")
    }

    @Test func opensWhatAServerSealsInAes128gcm() throws {
        let keys = WebPushCrypto.Keys.make()
        let text = Data("{\"title\":\"Anna Ek\",\"body\":\"Lunch after the review?\"}".utf8)
        #expect(try WebPushCrypto.open(Sender.aes128gcm(text, to: keys), coding: "aes128gcm", keys: keys) == text)
        // Records small enough that the message takes several.
        let long = Data((0..<300).map { UInt8($0 % 251) })
        #expect(try WebPushCrypto.open(Sender.aes128gcm(long, to: keys, recordSize: 64), coding: "aes128gcm", keys: keys) == long)
    }

    @Test func opensTheDraftsAesgcm() throws {
        let keys = WebPushCrypto.Keys.make()
        let text = Data("legacy sender".utf8)
        let sealed = Sender.aesgcm(text, to: keys, padding: 7)
        let plain = try WebPushCrypto.open(sealed.body, coding: "aesgcm", encryption: sealed.encryption, cryptoKey: sealed.cryptoKey, keys: keys)
        #expect(plain == text)
    }

    @Test func nothingElseOpens() throws {
        let keys = WebPushCrypto.Keys.make()
        var sealed = Sender.aes128gcm(Data("secret".utf8), to: keys)
        // Another subscription's keys.
        #expect(throws: (any Error).self) { try WebPushCrypto.open(sealed, coding: "aes128gcm", keys: .make()) }
        // A changed byte.
        sealed[sealed.count - 3] ^= 0x01
        #expect(throws: (any Error).self) { try WebPushCrypto.open(sealed, coding: "aes128gcm", keys: keys) }
        #expect(throws: (any Error).self) { try WebPushCrypto.open(Data([1, 2, 3]), coding: "aes128gcm", keys: keys) }
        #expect(throws: (any Error).self) { try WebPushCrypto.open(Data(), coding: "gzip", keys: keys) }
        #expect(throws: (any Error).self) { try WebPushCrypto.open(Data(repeating: 0, count: 40), coding: "aesgcm", encryption: "rs=4096", cryptoKey: "", keys: keys) }
    }

    @Test func readsTheDraftsHeaders() {
        #expect(WebPushCrypto.param("salt", in: "keyid=p256dh;salt=abc123") == "abc123")
        #expect(WebPushCrypto.param("dh", in: "dh=BAA_x; p256ecdsa=BBB") == "BAA_x")
        #expect(WebPushCrypto.param("p256ecdsa", in: "dh=BAA_x, p256ecdsa=\"BBB\"") == "BBB")
        #expect(WebPushCrypto.param("rs", in: "salt=x") == nil)
    }

    @MainActor
    @Test func aSubscriptionGivesThePageItsKeys() throws {
        let keys = WebPushCrypto.Keys.make()
        let record = WebPush.Record(id: "AAAAAAAAAAAAAAAAAAAAAA", endpoint: "https://push.test/v1/webpush/p/box.AAAAAAAAAAAAAAAAAAAAAA",
                                    origin: "https://app.example.com:443", scope: "https://app.example.com/", store: nil, key: "",
                                    secret: keys.privateKey.rawRepresentation.urlBase64, auth: keys.auth.urlBase64, made: Date())
        let reply = record.reply
        #expect(reply["endpoint"] as? String == record.endpoint)
        #expect((reply["p256dh"] as? String).flatMap(Data.init(urlBase64:)) == keys.publicKey)
        #expect((reply["auth"] as? String).flatMap(Data.init(urlBase64:))?.count == 16)
        // Kept and read back, the keys open what was sealed to them.
        let back = try JSONDecoder().decode(WebPush.Record.self, from: JSONEncoder().encode(record))
        let sealed = Sender.aes128gcm(Data("hi".utf8), to: keys)
        #expect(try WebPushCrypto.open(sealed, coding: "aes128gcm", keys: try #require(back.keys)) == Data("hi".utf8))
    }
}

/// A site's server, as the web-push libraries seal a message.
private enum Sender {
    static func aes128gcm(_ plain: Data, to keys: WebPushCrypto.Keys, recordSize: Int = 4096) -> Data {
        let server = P256.KeyAgreement.PrivateKey()
        let serverKey = server.publicKey.x963Representation
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let shared = shared(server, keys)
        let info = Data("WebPush: info".utf8) + [0] + keys.publicKey + serverKey
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: shared, salt: keys.auth, info: info, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm".utf8) + [0], outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce".utf8) + [0], outputByteCount: 12)
            .withUnsafeBytes { [UInt8]($0) }
        var out = salt
        out += [UInt8(recordSize >> 24 & 0xff), UInt8(recordSize >> 16 & 0xff), UInt8(recordSize >> 8 & 0xff), UInt8(recordSize & 0xff)]
        out += [65] + serverKey
        // Each record holds rs - 16 bytes of padded plaintext: data, a delimiter.
        let room = recordSize - 17
        var chunks: [Data] = []
        var at = 0
        repeat {
            let end = min(at + room, plain.count)
            chunks.append(plain.subdata(in: at..<end))
            at = end
        } while at < plain.count
        for (index, chunk) in chunks.enumerated() {
            let padded = chunk + [index == chunks.count - 1 ? 2 : 1]
            out += seal(padded, key: key, nonce: nonce, sequence: UInt64(index))
        }
        return out
    }

    static func aesgcm(_ plain: Data, to keys: WebPushCrypto.Keys, padding: Int) -> (body: Data, encryption: String, cryptoKey: String) {
        let server = P256.KeyAgreement.PrivateKey()
        let serverKey = server.publicKey.x963Representation
        let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let shared = shared(server, keys)
        let ikm = HKDF<SHA256>.deriveKey(inputKeyMaterial: shared, salt: keys.auth, info: Data("Content-Encoding: auth".utf8) + [0], outputByteCount: 32)
        var context = Data("P-256".utf8)
        context.append(contentsOf: [0, 0, 65] as [UInt8])
        context.append(keys.publicKey)
        context.append(contentsOf: [0, 65] as [UInt8])
        context.append(serverKey)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aesgcm".utf8) + [0] + context, outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce".utf8) + [0] + context, outputByteCount: 12)
            .withUnsafeBytes { [UInt8]($0) }
        let padded = Data([UInt8(padding >> 8), UInt8(padding & 0xff)]) + Data(repeating: 0, count: padding) + plain
        return (seal(padded, key: key, nonce: nonce, sequence: 0), "salt=\(salt.urlBase64)", "dh=\(serverKey.urlBase64)")
    }

    private static func shared(_ server: P256.KeyAgreement.PrivateKey, _ keys: WebPushCrypto.Keys) -> SymmetricKey {
        let secret = try! server.sharedSecretFromKeyAgreement(with: keys.privateKey.publicKey)
        return SymmetricKey(data: secret.withUnsafeBytes { Data($0) })
    }

    private static func seal(_ plain: Data, key: SymmetricKey, nonce: [UInt8], sequence: UInt64) -> Data {
        var iv = nonce
        for i in 0..<6 { iv[11 - i] ^= UInt8(truncatingIfNeeded: sequence >> (8 * UInt64(i))) }
        let box = try! AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: iv))
        return box.ciphertext + box.tag
    }
}
