import Foundation
import Testing
@testable import Fast
@testable import MailCore

// The agent's way to set up mail beyond Gmail (MailSetup, docs/
// mail-providers.md): which new passwords Yab takes off a page, what the
// agent reads instead of them, and which cookies say a page is signed in.
struct MailSetupTests {
    func way(_ id: String) -> MailSetupWay {
        MailSetupWay.of(MailKnownProviders.by(id: id)!)!
    }

    @Test func eachPasswordIsKnownByItsShape() {
        #expect(way("icloud").fits("abcd-efgh-ijkl-mnop"))
        #expect(!way("icloud").fits("Abcd-efgh-ijkl-mnop"))
        #expect(!way("icloud").fits("abcd-efgh-ijkl"))
        #expect(way("yahoo").fits("abcd efgh ijkl mnop"))
        #expect(way("yahoo").fits("abcdefghijklmnop"))
        #expect(way("yandex").fits("abcdefghijklmnop"))
        #expect(way("zoho").fits("mT4rQbX9pL2z"))
        #expect(way("zoho").fits("mT4r QbX9 pL2z"))
        // A word or a number alone is no password.
        #expect(!way("zoho").fits("Applications"))
        #expect(!way("zoho").fits("123456789012"))
    }

    @Test func onlyProvidersWithAKnownPageHaveTheWay() {
        #expect(MailSetupWay.of(MailKnownProviders.by(id: "gmx")!) == nil)
        #expect(MailSetupWay.of(MailKnownProviders.by(id: "zoho-eu")!)?.cookieHosts == ["zoho.eu"])
        #expect(MailSetupWay.pageName(MailKnownProviders.by(id: "icloud")!) == "Apple Account")
    }

    @Test func theAgentReadsDotsWhereThePasswordWas() {
        let icloud = way("icloud")
        let answer: [String: Any] = [
            "text": "Your new app-specific password is abcd-efgh-ijkl-mnop. Done",
            "nodes": [["name": "abcd-efgh-ijkl-mnop"], ["name": "Sign-In and Security"]],
            "count": 3,
        ]
        let hidden = MailSetup.hide(answer, taken: nil, loose: icloud.loose) as! [String: Any]
        #expect(hidden["text"] as? String == "Your new app-specific password is \(MailSetup.hidden). Done")
        let nodes = hidden["nodes"] as! [[String: Any]]
        #expect(nodes[0]["name"] as? String == MailSetup.hidden)
        #expect(nodes[1]["name"] as? String == "Sign-In and Security")
        #expect(hidden["count"] as? Int == 3)
        // The one taken, as the page spaced it and as it was kept.
        let yahoo = MailSetup.hide("x abcd efgh ijkl mnop y abcdefghijklmnop", taken: "abcd efgh ijkl mnop", loose: nil) as! String
        #expect(yahoo == "x \(MailSetup.hidden) y \(MailSetup.hidden)")
        // Words of the page's own stay.
        let page = MailSetup.hide("account-settings-page-here", taken: nil, loose: icloud.loose) as! String
        #expect(page == "account-settings-page-here")
    }

    @Test func aSignInIsALiveCookieOfTheSite() {
        let apple = way("icloud")
        func cookie(_ name: String, _ domain: String, ends: Date? = nil) -> HTTPCookie {
            var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: "x", .domain: domain, .path: "/"]
            if let ends { props[.expires] = ends }
            return HTTPCookie(properties: props)!
        }
        #expect(MailSignedIn.live(cookie("myacinfo", ".apple.com"), apple))
        #expect(MailSignedIn.live(cookie("myacinfo", "idmsa.apple.com"), apple))
        #expect(!MailSignedIn.live(cookie("myacinfo", "notapple.com"), apple))
        #expect(!MailSignedIn.live(cookie("dslang", ".apple.com"), apple))
        #expect(!MailSignedIn.live(cookie("myacinfo", ".apple.com", ends: Date(timeIntervalSinceNow: -60)), apple))
    }

    @Test func theAgentIsToldNeverToTypeAPassword() {
        let words = MailSetup.words("me@zoho.com", provider: MailKnownProviders.by(id: "zoho")!)
        #expect(words.contains("never type a password"))
        #expect(words.contains("keep_password"))
        #expect(words.contains("step: imap"))
        #expect(!MailSetup.words("me@icloud.com", provider: MailKnownProviders.by(id: "icloud")!).contains("step: imap"))
    }
}
