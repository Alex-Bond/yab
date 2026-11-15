import Foundation
import Testing
@testable import MailCore

extension MailSyncTests {
    @Test func aNewMessageUsesTheThreadFromTheSendReceipt() async throws {
        let (store, gmail, fake) = world()
        try await MailSync(store: store, gmail: gmail).sync()
        let draft = MailDraft(to: [MailPerson(name: "Anna", address: "anna@fold.studio")],
                              subject: "Review", body: "Thursday works.", messageID: MailCompose.messageID(from: store.me))
        store.save(draft)
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.count == 1)
        #expect(store.view(label: "SENT", without: ["TRASH"], limit: 100).threads.map(\.id) == ["s1"])
        #expect(store.thread("s1")?.snippet == "Thursday works.")
    }

    @Test func acknowledgedReplyAppearsInSentBeforeAnotherSync() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        var draft = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: store.me))
        draft.body = "Paid."
        draft.messageID = MailCompose.messageID(from: store.me)
        store.save(draft)
        let before = fake.calls.count
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, gmail: gmail)

        #expect(store.view(label: "SENT", without: ["TRASH"], limit: 100).threads.contains { $0.id == "tb" })
        #expect(store.message("s1")?.snippet.hasPrefix("Paid.") == true)
        #expect(fake.calls[before...].contains("GET messages/s1"))
        #expect(!fake.calls[before...].contains("GET threads/tb"))
        #expect(store.pendingOps == 0 && store.draft(draft.id) == nil)
    }

    @Test func failedSentReadDoesNotRepeatTheAcknowledgedSend() async throws {
        let (store, initialGmail, fake) = world()
        var gmail = initialGmail
        seed(fake)
        let sync = MailSync(store: store, gmail: gmail)
        try await sync.sync()
        var draft = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: store.me))
        draft.body = "Paid."
        draft.messageID = MailCompose.messageID(from: store.me)
        store.save(draft)
        fake.tooFast["messages/s1"] = 1
        gmail.limitTries = 1
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.count == 1 && store.message("s1") == nil)
        #expect(store.pendingOps == 0 && store.draft(draft.id) == nil)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.count == 1)
        try await sync.sync()
        #expect(store.message("s1") != nil)
    }

    @Test func recoveredSendAlsoAppearsInSentWithoutSendingAgain() async throws {
        let (store, gmail, fake) = world()
        seed(fake)
        try await MailSync(store: store, gmail: gmail).sync()
        var draft = try #require(MailCompose.reply(to: store.messages(thread: "tb"), me: store.me))
        draft.body = "Paid."
        draft.messageID = MailCompose.messageID(from: store.me)
        store.save(draft)
        fake.dropAnswers = 1
        MailOps.act(.send, thread: draft.id, in: store)
        try await MailOps.flush(store, gmail: gmail)
        #expect(fake.sent.count == 1 && store.pendingOps == 1)
        try await MailOps.flush(store, gmail: gmail, now: { Date().addingTimeInterval(60) })
        #expect(fake.sent.count == 1 && store.pendingOps == 0)
        #expect(store.view(label: "SENT", without: ["TRASH"], limit: 100).threads.contains { $0.id == "tb" })
    }
}
