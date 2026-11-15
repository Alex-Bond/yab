import Foundation
import Testing
@testable import Fast

// The Google accounts Settings › Mail offers to connect, read from the list
// Google hands its own account menu (MailFound).
struct MailFoundTests {
    /// Google's answer as it comes: the list inside a script string, every
    /// quote and bracket written as \x.. and slashes escaped.
    static func page(_ entries: [String]) -> String {
        let list = "[\"gaia.l.a.r\",[" + entries.joined(separator: ",") + "]]"
        let escaped = list.replacingOccurrences(of: "\"", with: "\\x22").replacingOccurrences(of: "[", with: "\\x5b")
            .replacingOccurrences(of: "]", with: "\\x5d").replacingOccurrences(of: "/", with: "\\/")
        return "<!DOCTYPE html><html><body><script type=\"text/javascript\" nonce=\"x\">window.parent.postMessage('\(escaped)', 'https:\\/\\/mail.google.com');</script></body></html>"
    }

    @Test func readsTheSignedInOnes() {
        let found = MailFound.parse(Self.page([
            "[\"gaia.l.a\",1,\"Anna Lind\",\"Anna@Example.com\",\"https://lh3.googleusercontent.com/a/s48-c/photo.jpg\",1,1,0,null,1,\"1\",null,null,null,null,1,\"Anna\"]",
            "[\"gaia.l.a\",1,\"Anna at work\",\"anna@fold.studio\",\"https://lh3.googleusercontent.com/b/s48-c/photo.jpg\",0,0,1,null,1,\"2\",null,null,null,null,1,\"Anna\"]",
            // Listed, but signed out: no index, and signed out said at 14.
            "[\"gaia.l.a\",1,\"Old\",\"old@example.com\",\"https://lh3.googleusercontent.com/c/s48-c/photo.jpg\",0,null,null,null,0,\"3\",null,null,null,1,null,\"Old\"]",
        ]))
        #expect(found.map(\.email) == ["anna@example.com", "anna@fold.studio"])
        #expect(found.first?.name == "Anna Lind")
        #expect(found.first?.photo?.absoluteString == "https://lh3.googleusercontent.com/a/s96-c/photo.jpg")
    }

    @Test func nothingFromAnythingElse() {
        #expect(MailFound.parse("").isEmpty)
        #expect(MailFound.parse("<html>Error 400 (Bad Request)</html>").isEmpty)
        #expect(MailFound.parse(Self.page([])).isEmpty)
    }
}
