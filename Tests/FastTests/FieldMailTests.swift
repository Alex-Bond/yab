import Foundation
import Testing
import MailCore
@testable import Fast

// The mail the page in front is waiting on, first in Now (docs/mail.md,
// "Mail in Now").
struct FieldMailTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func code(_ address: String = "no-reply@dashlane.com", from: String = "Dashlane", ago: TimeInterval = 20) -> Mailed {
        let at = now.addingTimeInterval(-ago)
        return Mailed(from: from, address: address, subject: "Here is the code you asked for",
                      text: "Your new device verification code is: 283607", at: at, thread: "t-code", account: "a@b.c",
                      message: "m-code", read: MailCodeRead(code: "283607", shown: "283 607", purpose: .newDevice))
    }

    func note(_ subject: String = "LastPass Security Notification: Login attempt blocked", ago: TimeInterval = 20) -> Mailed {
        Mailed(from: "LastPass", address: "do-not-reply@mail.lastpass.com", subject: subject, text: "Someone used your password.",
               at: now.addingTimeInterval(-ago), thread: "t-note", account: "a@b.c", message: "m-note")
    }

    let linear = Mailed(from: "Linear", address: "notifications@linear.app", subject: "Your login link for Linear",
                        text: "Click the button below to log in to Linear.", at: Date(timeIntervalSince1970: 1_800_000_000 - 20),
                        thread: "t-link", account: "a@b.c",
                        html: #"<a href="https://linear.app/auth/email/verify?token=9f2c8e1a4b7d6c3e5f8a1b2c3d4e5f6a"><span>Log in to Linear</span></a>"#)

    @Test func theSitesOwnCode() throws {
        let pick = try #require(FieldMail.pick(in: [code()], host: "check.dashlane.com", now: now))
        guard case .code(let sent) = pick.what else { Issue.record("not a code"); return }
        #expect(sent.code == "283607")
        #expect(pick.own)
        #expect(pick.title == "New device")
        #expect(pick.detail == "Dashlane")
    }

    /// A box in an extension's window: no page of the site in front.
    @Test func anotherSitesCodeOnlyRightAfterItCame() throws {
        let pick = try #require(FieldMail.pick(in: [code()], host: "linear.app", now: now))
        #expect(!pick.own)
        #expect(FieldMail.pick(in: [code()], host: nil, now: now) != nil)
        #expect(FieldMail.pick(in: [code(ago: FieldMail.away + 5)], host: "linear.app", now: now) == nil)
        // On its own site it stands as long as a code is fresh.
        #expect(FieldMail.pick(in: [code(ago: FieldMail.away + 5)], host: "dashlane.com", now: now) != nil)
    }

    @Test func aLinkFromTheSite() throws {
        let pick = try #require(FieldMail.pick(in: [linear], host: "linear.app", now: now))
        guard case .link = pick.what else { Issue.record("not a link"); return }
        #expect(pick.title == "Sign in to Linear")
        #expect(pick.detail == "Your login link for Linear")
    }

    @Test func aWordAboutTheSignIn() throws {
        let pick = try #require(FieldMail.pick(in: [note()], host: "lastpass.com", now: now))
        #expect(pick.what == .note)
        #expect(pick.title == "Login attempt blocked")
        #expect(pick.detail == "LastPass")
        #expect(FieldMail.pick(in: [note()], host: "linear.app", now: now) == nil)
    }

    /// A site's everyday mail is not Now's: GitHub's page, GitHub's mail.
    @Test func ordinaryMailStaysInMail() {
        #expect(FieldMail.pick(in: [note("Your weekly digest")], host: "lastpass.com", now: now) == nil)
    }

    @Test func goesWhenItsTimeIsOverOrItWasRead() {
        #expect(FieldMail.pick(in: [note(ago: MailLinks.fresh + 5)], host: "lastpass.com", now: now) == nil)
        var read = note()
        read.unread = false
        #expect(FieldMail.pick(in: [read], host: "lastpass.com", now: now) == nil)
        var junk = note()
        junk.junk = true
        #expect(FieldMail.pick(in: [junk], host: "lastpass.com", now: now) == nil)
    }

    @Test func aUsedCodeOrADoneRowGoes() {
        #expect(FieldMail.pick(in: [code()], host: "dashlane.com", now: now, live: { _ in false }) == nil)
        let done: Set<String> = [FieldMail.key(note())]
        #expect(FieldMail.pick(in: [note()], host: "lastpass.com", now: now, closed: done) == nil)
    }

    @Test func aCodeBeforeALink() throws {
        let pick = try #require(FieldMail.pick(in: [linear, code("no-reply@linear.app", from: "Linear")], host: "linear.app", now: now))
        guard case .code = pick.what else { Issue.record("not the code"); return }
    }

    @Test func theShorterOfTwoLifetimes() throws {
        let at = now
        let read = try #require(MailCodeWords.read(
            subject: "Here is the code you asked for",
            text: "This code expires in 3 hours.\nYour new device verification code is: 283607\nThis unique code will expire in 15 minutes.",
            received: at))
        #expect(read.expires == at.addingTimeInterval(15 * 60))
    }
}
