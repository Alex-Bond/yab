import Foundation
import Testing
@testable import Fast

// The extension id read out of what was pasted: a bare id or a store link.
struct CrxTests {
    let id = "abcdefghijklmnopabcdefghijklmnop"

    @Test func idsAndLinks() {
        #expect(Crx.id(in: id) == id)
        #expect(Crx.id(in: id.uppercased()) == id)
        #expect(Crx.id(in: "https://chromewebstore.google.com/detail/name/\(id)") == id)
        #expect(Crx.id(in: "x\(id)") == nil)
        #expect(Crx.id(in: "\(id)q") == nil)
    }

    /// "İ" lowercases longer, "i̇": the id is found in the text's own places,
    /// not a lowercased copy's, which missed it or cut the wrong letters.
    @Test func lettersThatLowercaseLonger() {
        #expect(Crx.id(in: "İ \(id)") == id)
        #expect(Crx.id(in: "İİİ x \(id) yz") == id)
    }
}

struct CrxFileTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func local() throws -> Data {
        try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/crx-local/local.crx"))
    }

    @Test func storePackageIdentityIsAuthenticated() throws {
        let id = "dbepggeogbaibhgnhhndojpepiihcmeb"
        let file = root.appendingPathComponent("evals/extensions/frozen-vimium/\(id)-3198c26aa719be462dea585050fbed9b8b80628d57ea88a113babf5334c5517c.crx")
        #expect(try Crx.id(inPackage: Data(contentsOf: file)) == id)
    }

    @Test func selfPackedIdentityIsAuthenticated() throws {
        let data = try local()
        let id = try Crx.id(inPackage: data)
        #expect(id.count == 32)
        #expect(!(try Crx.verifiedPackage(data, id: id)).zip.isEmpty)
    }

    @Test func alteredPackageIsRefused() throws {
        var data = try local()
        data[data.count - 1] ^= 1
        #expect(throws: Crx.Refused.self) { try Crx.id(inPackage: data) }
    }

    @Test func crx2IsRefused() throws {
        var data = try local()
        data[4] = 2
        #expect(throws: Crx.Refused.self) { try Crx.id(inPackage: data) }
    }

    @Test func unsignedAndWrongIdentityAreRefused() throws {
        let data = try local()
        #expect(throws: Crx.Refused.self) {
            try Crx.verifiedPackage(data, id: String(repeating: "a", count: 32))
        }
        var unsigned = Data("Cr24".utf8)
        unsigned.append(contentsOf: [3, 0, 0, 0, 0, 0, 0, 0, 1])
        #expect(throws: Crx.Refused.self) { try Crx.id(inPackage: unsigned) }
    }

    @Test func malformedHeaderLengthIsRefusedWithoutOverflow() {
        var data = Data("Cr24".utf8)
        data.append(contentsOf: [3, 0, 0, 0, 10, 0, 0, 0])
        data.append(contentsOf: [0x12] + Array(repeating: UInt8(0xff), count: 8) + [0x7f])
        data.append(0)
        #expect(throws: Crx.Refused.self) {
            try Crx.verifiedPackage(data, id: String(repeating: "a", count: 32))
        }
        #expect(throws: Crx.Refused.self) { try Crx.id(inPackage: data) }
    }

    @Test func storeUpdateURLMustBeTheStore() {
        #expect(Extensions.storeUpdateURL(nil))
        #expect(Extensions.storeUpdateURL("https://clients2.google.com/service/update2/crx"))
        #expect(!Extensions.storeUpdateURL("https://clients2.google.com.evil.test/service/update2/crx"))
        #expect(!Extensions.storeUpdateURL("https://example.com/update"))
    }
}
