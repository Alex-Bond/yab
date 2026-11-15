import Foundation
import Testing
import MailCore
@testable import Fast

// A sign-in link mailed by the site of the page in front, offered in the
// corner (docs/mail.md, Sign-in links from mail).
struct MailLinksTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func mail(_ html: String, from address: String = "notifications@linear.app", subject: String = "Your login link for Linear",
              text: String = "Click the button below to log in to Linear.", ago: TimeInterval = 20) -> Mailed {
        Mailed(from: "Linear", address: address, subject: subject, text: text, at: now.addingTimeInterval(-ago),
               thread: "t1", account: "anna@tern.app", html: html)
    }

    let linear = #"""
    <p>Click the button below to log in to Linear.</p>
    <a href="https://linear.app/auth/email/verify?token=9f2c8e1a4b7d6c3e5f8a1b2c3d4e5f6a&amp;email=anna%40tern.app" style="x"><span>Log in to Linear</span></a>
    <p><a href="https://linear.app/privacy">Privacy</a> · <a href="https://linear.app/unsubscribe?u=1">Unsubscribe</a></p>
    """#

    @Test func findsTheButtonOnTheSitesHost() throws {
        let found = try #require(MailLinks.found(in: [mail(linear)], for: "linear.app", now: now))
        #expect(found.url.absoluteString == "https://linear.app/auth/email/verify?token=9f2c8e1a4b7d6c3e5f8a1b2c3d4e5f6a&email=anna%40tern.app")
        #expect(found.site == "linear.app")
        #expect(MailLinks.name(found) == "Linear")
    }

    @Test func onlyFromTheSiteOfThePage() {
        // Another sender, or the page on another site: nothing.
        #expect(MailLinks.found(in: [mail(linear, from: "hello@evil.example")], for: "linear.app", now: now) == nil)
        #expect(MailLinks.found(in: [mail(linear)], for: "github.com", now: now) == nil)
    }

    @Test func linkToAnotherHostNeedsSigninButtonAndKnownHost() {
        let elsewhere = #"<a href="https://phish.example/login?token=abcdefabcdefabcdefabcdefabcdef">Log in to Linear</a>"#
        #expect(MailLinks.found(in: [mail(elsewhere)], for: "linear.app", now: now) == nil)
        let supabase = #"<a href="https://xyzcompany.supabase.co/auth/v1/verify?token=abcdefabcdefabcdef&type=magiclink">Sign in</a>"#
        #expect(MailLinks.found(in: [mail(supabase)], for: "linear.app", now: now)?.url.host() == "xyzcompany.supabase.co")
    }

    @Test func staleOrOfferedMailIsLeft() throws {
        #expect(MailLinks.found(in: [mail(linear, ago: 10 * 60)], for: "linear.app", now: now) == nil)
        let found = try #require(MailLinks.found(in: [mail(linear)], for: "linear.app", now: now))
        #expect(MailLinks.found(in: [mail(linear)], for: "linear.app", now: now, offered: [found.key]) == nil)
    }

    @Test func aNewsletterIsNotASignIn() {
        let news = #"<a href="https://linear.app/changelog/2026-10-10-new-views">Read the changelog</a>"#
        #expect(MailLinks.found(in: [mail(news, subject: "What's new in Linear", text: "New views and faster search.")],
                                for: "linear.app", now: now) == nil)
    }

    @Test func plainTextMailGivesItsLink() throws {
        let text = "Sign in to Notion:\nhttps://www.notion.so/loginwithemail?state=abc123def456ghi789jkl012mno345\n\nIf you didn't request this, ignore it."
        let item = Mailed(from: "Notion Team", address: "notify@mail.notion.so", subject: "Your Notion login link", text: text,
                          at: now.addingTimeInterval(-5), thread: "t2", account: "a")
        let found = try #require(MailLinks.found(in: [item], for: "www.notion.so", now: now))
        #expect(found.url.host() == "www.notion.so")
        #expect(MailLinks.name(found) == "Notion")
    }

    @Test func plainHttpOnlyToThisMac() {
        let http = #"<a href="http://linear.app/auth/verify?token=abcdefabcdefabcdefabcdefabcdef">Log in</a>"#
        #expect(MailLinks.found(in: [mail(http)], for: "linear.app", now: now) == nil)
        let local = #"<a href="http://127.0.0.1:8751/auth/verify?token=abcdefabcdefabcdefabcdefabcdef">Log in</a>"#
        #expect(MailLinks.found(in: [mail(local, from: "links@127.0.0.1")], for: "127.0.0.1", now: now) != nil)
    }

    @Test func aReadMailIsLeft() {
        var item = mail(linear)
        item.unread = false
        #expect(MailLinks.found(in: [item], for: "linear.app", now: now) == nil)
    }

    @Test func theSmallPrintIsNeverTheWayIn() {
        let links = MailLinkWords.links(html: linear, text: nil)
        #expect(links.count == 1)
        #expect(!links.contains { $0.url.path.contains("unsubscribe") || $0.url.path.contains("privacy") })
    }
}
