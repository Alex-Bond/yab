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
