import Foundation
import Testing
@testable import Fast

// Chromium's password recipe, pinned to vectors made without this code:
// Python's hashlib (PBKDF2-HMAC-SHA1, "saltysalt", 1003 rounds, 16 bytes)
// and the `cryptography` package (AES-128-CBC, an IV of sixteen spaces,
// PKCS#7), so a test that passes says the recipe is Chromium's, not that
// the code agrees with itself.
struct ChromiumPasswordsTests {
    static let passphrase = "fast-test-passphrase"
    static let key = bytes("f0e48613b015ee91e56768f3def2a0c1")
    /// "v10" + AES of "hunter2-correct horse".
    static let blob = Data(bytes("763130958f55cf6293416d99bec06d063361121bedb6f878e2a8d3290bebc4c397412c"))
    /// "v10" + AES of SHA-256("example.com") + "pässwörd ✓", as newer
    /// Chromium writes it.
    static let prefixed = Data(bytes("76313021a668312966fb049052867193deb0cbd86bd528e37370a5f02f04be5d428356a9da54ee0399d5dc3d7d3ff407b6ca7c"))

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    @Test func stretchesTheWayChromiumDoes() {
        #expect(Chromium.stretch(Self.passphrase) == Self.key)
        #expect(Chromium.stretch("") == Self.bytes("1cbee826d6938327ae9043f63bfc26d7"))
        // Lean's vector, made the same way on another machine.
        #expect(Chromium.stretch("lean-test-passphrase") == Self.bytes("4c1cad805755cde75f2ad720789bb738"))
    }

    @Test func unwrapsAVersionTenBlob() {
        #expect(Chromium.unwrap(Self.blob, key: Self.key) == "hunter2-correct horse")
        #expect(Chromium.unwrap(Self.blob, key: Chromium.stretch(Self.passphrase)) == "hunter2-correct horse")
    }

    @Test func skipsTheSiteHashNewerBuildsPutInFront() {
        #expect(Chromium.unwrap(Self.prefixed, key: Self.key) == "pässwörd ✓")
    }

    @Test func aWrongKeyGivesNothingRatherThanJunk() {
        #expect(Chromium.unwrap(Self.blob, key: [UInt8](repeating: 0, count: 16)) == nil)
        #expect(Chromium.unwrap(Self.blob, key: [UInt8](repeating: 7, count: 16)) == nil)
    }

    @Test func oldUnencryptedValuesPassThrough() {
        #expect(Chromium.unwrap(Data("old-secret".utf8), key: Self.key) == "old-secret")
    }

    @Test func heliumIsFoundUnderItsOwnNames() throws {
        // imputnet/helium-macos: change-keychain-name.patch and
        // change-product-dir-name.patch; the bundle id from imputnet/helium's
        // change-chromium-branding.patch.
        let helium = try #require(Chromium.known.first { $0.name == "Helium" })
        #expect(helium.folder == "net.imput.helium")
        #expect(helium.service == "Helium Storage Key")
        #expect(helium.account == "Helium")
        #expect(helium.bundle == "net.imput.helium")
    }
}
