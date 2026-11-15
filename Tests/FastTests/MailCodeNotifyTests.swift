import Testing
import UserNotifications
@testable import Fast

struct MailCodeNotifyTests {
    @Test func codeActionsAndBatchKeepTheMessageIdentity() throws {
        let read = MailCodeRead(code: "481902", shown: "481 902", purpose: .purchase, amount: "$42.00", merchant: "AWS")
        let note = MailNotify.Note(thread: "t", message: "m", who: "Brex", subject: "Verification", line: "", at: .now, code: read)
        let posts = MailNotify.posts(Array(repeating: note, count: 4), account: "me", mode: .inbox, accounts: 1)
        #expect(posts.count == 4)
        #expect(posts.allSatisfy { $0.title == "Brex · 481 902" && $0.codeMessage == "m" && !$0.batch })
        #expect(posts.first?.body.contains("$42.00") == true)
        let category = try #require(MailNotifySystem.categories.first { $0.identifier == MailNotify.codeCategory })
        #expect(category.actions.map(\.identifier) == ["copyCode", "done"])
        #expect(category.actions.first?.options.contains(.foreground) == false)
    }
}
