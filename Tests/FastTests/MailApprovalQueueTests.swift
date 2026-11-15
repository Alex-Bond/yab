import AppKit
import Foundation
import Testing
@testable import Fast
@testable import MailCore
import MailCoreFakes

@MainActor
@Suite(.serialized)
struct MailApprovalQueueTests {
    private func world() -> (MailCenter.Engine, FakeGmail) {
        let (store, gmail, fake) = MailWorld.make(host: "approval-queue-\(UUID().uuidString.prefix(8)).test")
        store.set("me", "me@example.com")
        return (MailCenter.Engine(account: store.me, store: store, gmail: gmail,
                                  sync: MailSync(store: store, gmail: gmail)), fake)
    }

    private func outgoing(_ engine: MailCenter.Engine, _ n: Int) -> MailAgent.Outgoing {
        let draft = MailDraft(id: "new:queue-\(n)", to: [MailPerson(name: "Person \(n)", address: "person\(n)@example.com")],
                              subject: "Queue \(n)", body: "Fixture \(n).")
        engine.store.save(draft)
        return MailAgent.Outgoing(engine: engine, draft: draft, ready: nil)
    }

    @Test func twentyFiveCallsKeepTheirArrivalOrderAndSendExactlyOnce() async throws {
        let (engine, fake) = world(), agents = Agents(), tab = Tab(bench: true, factory: .webKitOnly)
        defer { tab.close() }
        let outs = (0..<25).map { outgoing(engine, $0) }
        var ids: [String] = []
        for (n, out) in outs.enumerated() {
            let waiting = await agents.sendMail(out, in: tab, session: "caller-\(n)", mode: .auto, hold: 0)
            ids.append(try #require(waiting["mailAsk"] as? String))
            #expect(agents.mailRequests.map(\.id) == ids)
        }
        #expect(tab.permit == nil, "Mail requests do not overwrite a page's permit slot")
        #expect(fake.sent.isEmpty)
        let joined = await agents.sendMail(outs[12], in: tab, session: "joined-caller", mode: .bypass, hold: 0)
        #expect(joined["mailAsk"] as? String == ids[12])
        #expect(agents.mailRequests.map(\.id) == ids)
        for n in 0..<25 {
            #expect(agents.mailRequests.first?.id == ids[n])
            agents.answerMail(ids[n], yes: true)
            // A second press while dispatch runs cannot start another send.
            agents.answerMail(ids[n], yes: true)
            let result = await agents.sendMail(outs[n], in: tab, session: "caller-\(n)", mode: .auto, hold: 0)
            #expect(result["sent"] as? Bool == true)
            #expect(agents.mailRequests.map(\.id) == Array(ids.dropFirst(n + 1)))
        }
        let joinedResult = await agents.sendMail(outs[12], in: tab, session: "joined-caller", mode: .auto, hold: 0)
        #expect(joinedResult["sent"] as? Bool == true)
        #expect(fake.sent.count == 25)
        #expect(agents.mailRequests.isEmpty)
    }

    @Test func endingTheOriginalSessionDoesNotLoseItsMailOrAnotherCallersAnswer() async throws {
        let (engine, fake) = world(), agents = Agents(), tab = Tab(bench: true, factory: .webKitOnly)
        defer { tab.close() }
        let out = outgoing(engine, 1)
        agents.benchTask("original-mail-caller", state: .running)
        let first = await agents.sendMail(out, in: tab, session: "original-mail-caller", mode: .auto, hold: 0)
        let id = try #require(first["mailAsk"] as? String)
        _ = await agents.sendMail(out, in: tab, session: "joined-mail-caller", mode: .auto, hold: 0)
        agents.leave(try #require(agents.session("original-mail-caller")))
        #expect(agents.mailRequests.first?.id == id)
        agents.answerMail(id, yes: true)
        let sent = await agents.sendMail(out, in: tab, session: "joined-mail-caller", mode: .auto, hold: 0)
        #expect(sent["sent"] as? Bool == true)
        #expect(fake.sent.count == 1)
    }

    @Test func anOperationWithNoRemainingCallerStillSendsOnItsOwnYes() async throws {
        let (engine, fake) = world(), agents = Agents()
        let out = outgoing(engine, 1)
        let caller = agents.attach(name: "queue fixture")
        let waiting = await agents.queueMail([out], session: caller.id, hold: 0)
        let id = try #require(waiting["mailAsk"] as? String)
        let operation = try #require(agents.mailRequest(id))
        agents.leave(caller)
        #expect(operation.callers.isEmpty)
        #expect(agents.mailRequest(id) === operation)
        agents.answerMail(id, yes: true)
        let task = try #require(operation.task)
        let result = await task.value
        #expect(result["sent"] as? Bool == true)
        #expect(fake.sent.count == 1)
        #expect(agents.mailRequests.isEmpty && agents.mailReceipts[id] == nil)
    }

    @Test func aCompletedCallReturnsItsReceiptAfterItsDraftIsGone() async throws {
        let (engine, fake) = world(), agents = Agents()
        let out = outgoing(engine, 1)
        let call = try #require(Agents.mailCall(["draft": engine.account + "|" + out.draft.id]))
        let waiting = await agents.queueMail([out], session: "receipt-caller", hold: 0, call: call)
        agents.answerMail(try #require(waiting["mailAsk"] as? String), yes: true)
        let result = try #require(await agents.completedMailCall(call, session: "receipt-caller"))
        #expect(result["sent"] as? Bool == true)
        #expect(engine.store.draft(out.draft.id) == nil)
        #expect(fake.sent.count == 1)
        #expect(await agents.completedMailCall(call, session: "another-caller") == nil)
    }

    @Test func aDeclineIsSharedWithoutDecliningAnUnrelatedMail() async throws {
        let (engine, fake) = world(), agents = Agents(), tab = Tab(bench: true, factory: .webKitOnly)
        defer { tab.close() }
        let out = outgoing(engine, 1), next = outgoing(engine, 2)
        let first = await agents.sendMail(out, in: tab, session: "first", mode: .auto, hold: 0)
        let id = try #require(first["mailAsk"] as? String)
        _ = await agents.sendMail(out, in: tab, session: "duplicate", mode: .auto, hold: 0)
        let second = await agents.sendMail(next, in: tab, session: "second", mode: .auto, hold: 0)
        agents.answerMail(id, yes: false)
        for session in ["first", "duplicate"] {
            let refused = await agents.sendMail(out, in: tab, session: session, mode: .auto, hold: 0)
            #expect((refused["error"] as? String)?.contains("not now") == true)
            #expect(refused["asking"] == nil)
        }
        #expect(agents.mailRequests.map(\.id) == [try #require(second["mailAsk"] as? String)])
        #expect(fake.sent.isEmpty)
    }

    @Test func aPageQuestionIsNotReplacedByMailAsks() async {
        let (engine, _) = world(), agents = Agents(), tab = Tab(bench: true, factory: .webKitOnly)
        defer { tab.permit = nil; tab.close() }
        let page = AgentPermit(kind: .use, session: "page-caller", detail: "Use this page")
        tab.permit = page
        _ = await agents.sendMail(outgoing(engine, 1), in: tab, session: "mail-caller", mode: .auto, hold: 0)
        #expect(tab.permit == page)
        #expect(agents.mailRequests.count == 1)
    }

    @Test func sendIdentityIncludesRecipientRolesSenderTimeAndAttachmentIdentity() {
        let (engine, _) = world()
        let out = outgoing(engine, 1)
        var changed = out
        changed.draft.cc = changed.draft.to; changed.draft.to = []
        #expect(changed.key != out.key)
        changed = out; changed.draft.from = "alias@example.com"
        #expect(changed.key != out.key)
        changed = out; changed.at = Date().addingTimeInterval(3600)
        #expect(changed.key != out.key)
        changed = out; changed.draft.html = "<p>Different markup</p>"
        #expect(changed.key != out.key)
        var file = out
        file.draft.files = [.init(id: "one", name: "same.pdf", mime: "application/pdf", size: 123)]
        changed = file; changed.draft.files[0].id = "two"
        #expect(changed.key != file.key)
    }
}
