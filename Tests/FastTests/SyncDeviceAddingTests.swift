import Combine
import Foundation
import SyncKit
import Testing
@testable import Fast

@MainActor
struct SyncDeviceAddingTests {
    private func invite(_ box: PairBox) -> SyncInvite {
        SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: box, every: 0.02))
    }

    @Test func aCodeNobodyWaitsUnderIsAnotherMacsAndThisMacWaitsUnderIt() throws {
        let box = PairBox()
        var waited: [String] = []
        var stopped = 0
        let adding = SyncDeviceAdding(makeInvite: { invite(box) }, approveCode: { _, done in done(false) },
                                      joinCode: { waited.append($0) }, stopJoin: { stopped += 1 })
        adding.start()
        adding.edit("k7qm 4xtd")
        adding.approve()
        #expect(waited == ["K7QM4XTD"])
        #expect(adding.joining)
        #expect(adding.trouble == nil, "no error: the digits come next")
        adding.cancelJoin()
        #expect(stopped == 1)
        #expect(!adding.joining && adding.code.isEmpty)
        #expect(adding.invite != nil, "this Mac's own code is back")
        adding.stop()
    }

    @Test func leavingIgnoresTheApprovalThatWasAlreadyInFlight() throws {
        let box = PairBox()
        var answer: ((Bool) -> Void)?
        var approvals = 0
        let adding = SyncDeviceAdding(makeInvite: { invite(box) }, approveCode: { _, done in
            approvals += 1
            answer = done
        })
        adding.start()
        adding.edit("k7qm 4xtd")
        #expect(approvals == 0, "typing or pasting never lets a device in")
        adding.approve()
        adding.approve()
        #expect(approvals == 1, "double clicks do not approve twice")
        #expect(adding.busy)
        adding.stop()
        let respond = try #require(answer)
        respond(true)
        #expect(!adding.finished && !adding.busy)
        #expect(adding.invite == nil)
    }

    @Test func aNewPageCannotReceiveThePreviousPagesAnswer() throws {
        let box = PairBox()
        var answer: ((Bool) -> Void)?
        let adding = SyncDeviceAdding(makeInvite: { invite(box) }, approveCode: { _, done in answer = done })
        adding.start()
        adding.edit("K7QM4XTD")
        adding.approve()
        adding.start()
        let fresh = try #require(adding.invite)
        let respond = try #require(answer)
        respond(false)
        #expect(adding.invite === fresh)
        #expect(adding.trouble == nil && adding.code.isEmpty && !adding.busy)
        adding.stop()
    }

    @Test func aCodeThatFailsAllowsRetryWithAFreshQR() throws {
        let box = PairBox()
        var answer: ((Bool) -> Void)?
        let words = PassthroughSubject<String?, Never>()
        let adding = SyncDeviceAdding(makeInvite: { invite(box) }, approveCode: { _, done in answer = done },
                                      joinCode: { _ in }, stopJoin: {}, joinWords: words.eraseToAnyPublisher())
        adding.start()
        let first = try #require(adding.invite)
        adding.edit("K7QM4XTD")
        adding.approve()
        let respond = try #require(answer)
        respond(false)
        words.send("That code ran out. On the other Mac, choose Add a Device for a new one.")
        #expect(adding.invite !== first)
        #expect(adding.trouble != nil && !adding.finished && !adding.busy)
        #expect(adding.code == "K7QM4XTD")
        // The field handing the same text back (it does on coming back)
        // keeps the words saying why.
        adding.edit("K7QM-4XTD")
        #expect(adding.trouble != nil)
        adding.edit("ABCD EFGH")
        #expect(adding.trouble == nil)
        adding.approve()
        let retryAnswer = try #require(answer)
        retryAnswer(true)
        #expect(adding.finished && !adding.busy)
        adding.stop()
    }

    @Test func scanningWaitsForTheDigitsAndRejectingRevokesTheOldQR() async throws {
        let box = PairBox()
        var sent = 0
        let seal = Seal.make()
        let adding = SyncDeviceAdding(makeInvite: { invite(box) }, letIn: {
            sent += 1
            $0.letIn(seal)
        })
        adding.start()
        let first = try #require(adding.invite)
        adding.confirm()
        #expect(sent == 0)
        let phone = Joining(code: first.code)
        box.post(Joining.box(first.code), pub: phone.posted)
        #expect(await until { if case .arrived = first.phase { return true }; return false })
        #expect(box.envelope(Joining.box(first.code)) == nil, "a scan alone never sends the key")
        adding.start() // Not This One
        first.letIn(seal)
        try await Task.sleep(for: .milliseconds(100))
        #expect(box.envelope(Joining.box(first.code)) == nil)
        let second = try #require(adding.invite)
        let other = Joining(code: second.code)
        box.post(Joining.box(second.code), pub: other.posted)
        #expect(await until { if case .arrived = second.phase { return true }; return false })
        adding.confirm()
        #expect(await until { adding.finished })
        #expect(sent == 1)
        let envelope = try #require(box.envelope(Joining.box(second.code)))
        #expect(try other.open(envelope).raw == seal.raw)
        adding.stop()
    }

    private func until(_ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }
}
