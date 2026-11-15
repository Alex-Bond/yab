import CryptoKit
import Foundation
import Security

/// A Chrome extension straight from the Chrome Web Store, as Yab for Mac
/// takes one (Sources/Fast/Crx.swift): the .crx from the public update
/// address every Chromium browser asks, its header checked (a public key
/// hashing to the id asked for, and its signature over the zip), the zip
/// unpacked for WebKit. On iOS the key is read out of its SubjectPublicKeyInfo
/// by hand (no SecItemImport) and the zip by ZipReader (no ditto).
enum ExtensionPackage {
    enum Refused: LocalizedError {
        case notAnID, download(Int), empty, notCrx, unsignedOrWrong, unpack

        var errorDescription: String? {
            switch self {
            case .notAnID: "Not a Web Store link or ID"
            case .download(let code): "The Web Store said error \(code)"
            case .empty: "No extension with that ID"
            case .notCrx: "That isn't a Chrome extension"
            case .unsignedOrWrong: "Its signature doesn't check out"
            case .unpack: "Couldn't open the package"
            }
        }
    }

    /// The Chrome the store is told it talks to (the Mac's number).
    static let chromeVersion = "140.0.0.0"

    /// Thirty-two letters a to p: a bare id or one inside a store link.
    static func id(in text: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "(?<![a-z])([a-p]{32})(?![a-z])", options: .caseInsensitive)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range), let found = Range(match.range(at: 1), in: text) else { return nil }
        return text[found].lowercased()
    }

    /// The store's own page for an extension: its id, when this is one.
    static func storeID(of url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased(),
              host == "chromewebstore.google.com" || (host == "chrome.google.com" && url.path.hasPrefix("/webstore")) else { return nil }
        return id(in: url.path)
    }

    static func downloadURL(for id: String) -> URL {
        var parts = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        parts.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: chromeVersion),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc"),
        ]
        return parts.url!
    }

    static func fetch(_ id: String) async throws -> Data {
        var request = URLRequest(url: downloadURL(for: id))
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Refused.download(http.statusCode) }
        guard !data.isEmpty else { throw Refused.empty }
        return data
    }

    /// The zip inside a CRX3, once its signature checks out against `id`.
    static func verifiedZip(_ crx: Data, id: String) throws -> Data {
        let bytes = [UInt8](crx)
        guard bytes.count > 12, Array(bytes[0..<4]) == Array("Cr24".utf8), le32(bytes, 4) == 3 else { throw Refused.notCrx }
        let headerSize = Int(le32(bytes, 8))
        guard 12 + headerSize <= bytes.count else { throw Refused.notCrx }
        let header = Array(bytes[12..<(12 + headerSize)])
        let zip = Data(bytes[(12 + headerSize)...])
        let fields = protobuf(header)
        guard let signedHeader = fields.first(where: { $0.0 == 10000 })?.1,
              let crxID = protobuf(signedHeader).first(where: { $0.0 == 1 })?.1, letters(crxID) == id else { throw Refused.unsignedOrWrong }
        var message = Data("CRX3 SignedData".utf8)
        message.append(0)
        var length = UInt32(signedHeader.count).littleEndian
        message.append(Data(bytes: &length, count: 4))
        message.append(Data(signedHeader))
        message.append(zip)
        let owns = fields.filter { $0.0 == 2 }.map { protobuf($0.1) }.contains { proof in
            guard let key = proof.first(where: { $0.0 == 1 })?.1, let signature = proof.first(where: { $0.0 == 2 })?.1,
                  letters(Array(SHA256.hash(data: Data(key)).prefix(16))) == id else { return false }
            return verify(spki: key, signature: Data(signature), message: message)
        }
        guard owns else { throw Refused.unsignedOrWrong }
        return zip
    }

    /// Unpacked into `folder`, which is replaced whole once it opened.
    static func unpack(_ zip: Data, into folder: URL) throws {
        let files = FileManager.default
        let scratch = files.temporaryDirectory.appendingPathComponent("yab-crx-\(UUID().uuidString)", isDirectory: true)
        defer { try? files.removeItem(at: scratch) }
        do { try ZipReader.unpack(zip, into: scratch) } catch { throw Refused.unpack }
        guard files.fileExists(atPath: scratch.appendingPathComponent("manifest.json").path) else { throw Refused.unpack }
        try? files.removeItem(at: folder)
        try files.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try files.moveItem(at: scratch, to: folder)
    }

    // MARK: - pieces

    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }

    static func letters(_ bytes: [UInt8]) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 0x0f] }.map { Character(UnicodeScalar(UInt8(97) + $0)) })
    }

    private static func protobuf(_ b: [UInt8]) -> [(Int, [UInt8])] {
        var out: [(Int, [UInt8])] = []
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < b.count {
                let byte = Int(b[i]); i += 1
                value |= (byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { break }
            switch key & 7 {
            case 2:
                guard let length = varint(), i + length <= b.count else { return out }
                out.append((key >> 3, Array(b[i..<(i + length)])))
                i += length
            case 0: _ = varint()
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }

    /// SubjectPublicKeyInfo: SEQUENCE { AlgorithmIdentifier, BIT STRING
    /// { RSAPublicKey } }. iOS takes the PKCS#1 RSAPublicKey inside.
    static func rsaKey(fromSPKI b: [UInt8]) -> [UInt8]? {
        var i = 0
        func length() -> Int? {
            guard i < b.count else { return nil }
            let first = Int(b[i]); i += 1
            if first < 0x80 { return first }
            let n = first & 0x7f
            guard n > 0, n <= 4, i + n <= b.count else { return nil }
            var value = 0
            for _ in 0..<n { value = value << 8 | Int(b[i]); i += 1 }
            return value
        }
        guard i < b.count, b[i] == 0x30 else { return nil }
        i += 1; guard length() != nil else { return nil }
        guard i < b.count, b[i] == 0x30 else { return nil }
        i += 1; guard let algorithm = length() else { return nil }
        i += algorithm
        guard i < b.count, b[i] == 0x03 else { return nil }
        i += 1; guard let bits = length(), bits > 1, i + bits <= b.count, b[i] == 0 else { return nil }
        return Array(b[(i + 1)..<(i + bits)])
    }

    private static func verify(spki: [UInt8], signature: Data, message: Data) -> Bool {
        guard let pkcs1 = rsaKey(fromSPKI: spki),
              let key = SecKeyCreateWithData(Data(pkcs1) as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA,
                                                                    kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, signature as CFData, nil)
    }
}
