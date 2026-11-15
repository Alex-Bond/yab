import Foundation
import MailCore
import Testing
@testable import Fast

struct MailCodeMatchingTests {
    let now = Date(timeIntervalSince1970: 1000)
    func message(_ code: String, ago: Double, address: String = "security@brex.com", junk: Bool = false) -> Mailed {
        Mailed(from: "Brex", address: address, subject: "Your sign-in code", text: "Code: " + code,
               at: now.addingTimeInterval(-ago), junk: junk)
    }
    func codes(_ mail: [Mailed], since: Date? = nil) -> [SentCode] {
        MailCodeMatching.codes(in: mail, now: now, since: since) { $0.address == "security@brex.com" }
    }

    @Test func futureAndJunkMailCannotReplaceTheCurrentCode() {
        let mail = [message("111111", ago: 30), message("222222", ago: -90), message("333333", ago: 5, junk: true),
                    message("444444", ago: 5, address: "forged@other.test")]
        #expect(codes(mail).map(\.code) == ["111111"])
    }
    @Test func resendReplacesOnlyTheSameSenderAndCurrentRequest() {
        let old = message("111111", ago: 60), new = message("222222", ago: 5)
        #expect(codes([old, new]).map(\.code) == ["222222"])
        #expect(codes([old], since: now.addingTimeInterval(-30)).isEmpty)
    }
    @Test func explicitLifetimeAndStableMessageIdentity() {
        var old = message("111111", ago: 650)
        #expect(codes([old]).isEmpty)
        old.read = MailCodeRead(code: "111111", shown: "111 111", expires: now.addingTimeInterval(30))
        old.account = "me@example.com"; old.message = "m1"; old.thread = "t1"
        let found = codes([old]).first
        #expect(found?.id == "mail:me@example.com:m1")
        #expect(found?.thread == "t1" && found?.message == "m1")
    }
    @Test func connectedMailWaitsForItsSharedParse() {
        var mail = message("111111", ago: 20)
        mail.account = "me@example.com"; mail.message = "m1"
        #expect(codes([mail]).isEmpty)
        mail.read = MailCodeRead(code: "111111", shown: "111 111")
        #expect(codes([mail]).map(\.code) == ["111111"])
    }

}
