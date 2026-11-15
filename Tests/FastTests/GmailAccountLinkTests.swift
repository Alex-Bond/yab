import Foundation
import Testing
@testable import Fast

struct GmailAccountLinkTests {
    @Test func accountByEmailGoesAsAuthuser() {
        let link = URL(string: "https://mail.google.com/mail/u/sam@42nd.dev/#all/1a0ff36f10793923")!
        #expect(Browser.gmailByPlace(link)?.absoluteString == "https://mail.google.com/mail/?authuser=sam@42nd.dev#all/1a0ff36f10793923")
    }

    @Test func accountByPlaceStays() {
        #expect(Browser.gmailByPlace(URL(string: "https://mail.google.com/mail/u/1/#inbox")!) == nil)
        #expect(Browser.gmailByPlace(URL(string: "https://example.com/mail/u/a@b.c/")!) == nil)
    }
}
