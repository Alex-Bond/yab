import Testing
@testable import Fast

@MainActor
struct FindSelectionRequestTests {
    @Test func currentReplyArrivesOnce() throws {
        let request = FindSelectionRequest()
        var reply: FindSelectionRequest.Reply?
        var received: [String] = []
        request.request(send: { reply = $0 }, receive: { received.append($0?["selection"] as? String ?? "nil") })
        let complete = try #require(reply)
        complete(["selection": "current"])
        complete(["selection": "duplicate"])
        #expect(received == ["current"])
    }

    @Test func synchronousNilReplyIsDeliveredOnce() {
        let request = FindSelectionRequest()
        var count = 0
        request.request(send: { $0(nil); $0(nil) }, receive: { answer in
            #expect(answer == nil)
            count += 1
        })
        #expect(count == 1)
    }

    @Test func closeRejectsTheReply() throws {
        let request = FindSelectionRequest()
        var reply: FindSelectionRequest.Reply?
        var count = 0
        request.request(send: { reply = $0 }, receive: { _ in count += 1 })
        request.cancel()
        let complete = try #require(reply)
        complete(["selection": "closed"])
        #expect(count == 0)
    }

    @Test(arguments: [false, true])
    func reopeningRejectsOldReplyInEitherOrder(newFirst: Bool) throws {
        let request = FindSelectionRequest()
        var replies: [FindSelectionRequest.Reply] = []
        var received: [String] = []
        request.request(send: { replies.append($0) }, receive: { received.append($0?["selection"] as? String ?? "nil") })
        request.cancel()
        request.request(send: { replies.append($0) }, receive: { received.append($0?["selection"] as? String ?? "nil") })
        try #require(replies.count == 2)
        for i in newFirst ? [1, 0] : [0, 1] { replies[i](["selection": i == 0 ? "old" : "new"]) }
        #expect(received == ["new"])
    }

    @Test func replacementInvalidatesWithoutClosing() throws {
        let request = FindSelectionRequest()
        var replies: [FindSelectionRequest.Reply] = []
        var received: [Int] = []
        for value in [1, 2] {
            request.request(send: { replies.append($0) }, receive: { _ in received.append(value) })
        }
        try #require(replies.count == 2)
        replies[0](nil)
        replies[1](nil)
        #expect(received == [2])
    }

    @Test func reentrantDeliveryKeepsTheNewRequest() throws {
        let request = FindSelectionRequest()
        var first: FindSelectionRequest.Reply?
        var second: FindSelectionRequest.Reply?
        var received: [Int] = []
        request.request(send: { first = $0 }, receive: { _ in
            received.append(1)
            request.request(send: { second = $0 }, receive: { _ in received.append(2) })
        })
        let complete = try #require(first)
        complete(nil)
        complete(nil)
        let completeSecond = try #require(second)
        completeSecond(nil)
        #expect(received == [1, 2])
    }

    @Test func independentOwnersDoNotCancelEachOther() throws {
        let a = FindSelectionRequest(), b = FindSelectionRequest()
        var replyA: FindSelectionRequest.Reply?, replyB: FindSelectionRequest.Reply?
        var received: [String] = []
        a.request(send: { replyA = $0 }, receive: { _ in received.append("a") })
        b.request(send: { replyB = $0 }, receive: { _ in received.append("b") })
        a.cancel()
        let completeA = try #require(replyA)
        completeA(nil)
        let completeB = try #require(replyB)
        completeB(nil)
        #expect(received == ["b"])
    }
}
