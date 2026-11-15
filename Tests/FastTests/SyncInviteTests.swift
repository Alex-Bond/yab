import CryptoKit
import AppKit
import Foundation
import SwiftUI
import SyncKit
import Testing
@testable import Fast

/// Add a Device's code for an iPhone to scan (JoinInvite, SyncInvite): the
/// QR holds the code alone, both screens show the same digits, nothing is
/// sealed before the Mac's yes; and Settings › Sync's words on the Mac.
struct SyncInviteTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Add a Device's code for an iPhone

    @MainActor
    @Test func theQRHoldsTheCodeAndNothingElse() throws {
        let code = JoinInvite.make()
        #expect(JoinInvite.link(code) == "yab://join/" + code)
        #expect(JoinInvite.code(scanned: JoinInvite.link(code)) == code)
        #expect(JoinInvite.code(scanned: "YAB://JOIN/" + code.lowercased()) == code)
        #expect(JoinInvite.code(scanned: code.replacingOccurrences(of: "-", with: " ").lowercased()) == code)
        #expect(JoinInvite.code(scanned: "https://example.com/join/" + code) == nil)
        #expect(JoinInvite.code(scanned: "yab://task/" + code) == nil)
        #expect(JoinInvite.code(scanned: "ABCD-EFG") == nil)
        #expect(JoinInvite.code(scanned: "ABCD-EFG0") == nil, "0 isn't one of a code's letters")
        let image = try #require(QRCode.image(JoinInvite.link(code), side: 132))
        #expect(QRCode.read(image) == "yab://join/" + code)
    }

    @Test func bothScreensShowTheSameFourDigits() {
        let joining = Joining(code: "K7QM-4XTD")
        let one = JoinInvite.check(code: "K7QM-4XTD", publicKey: joining.publicKey)
        #expect(one.count == 4 && one.allSatisfy(\.isNumber))
        #expect(JoinInvite.check(code: "k7qm4xtd", publicKey: joining.publicKey) == one)
        let other = (0..<8).map { _ in JoinInvite.check(code: "K7QM-4XTD", publicKey: Joining(code: "K7QM-4XTD").publicKey) }
        #expect(other.contains { $0 != one }, "another key, other digits")
    }

    @MainActor
    @Test func anIPhoneScanningTheMacsCodeIsLetInOnlyAfterTheDigits() async throws {
        let box = PairBox()
        let seal = Seal.make()
        let invite = SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: box, every: 0.02))
        var arrived: String?
        invite.start { arrived = $0 }
        #expect(invite.phase == .waiting)
        #expect(invite.words == nil)
        // The iPhone scans it and posts its key under the code.
        let phone = Joining(code: invite.code)
        box.post(Joining.box(invite.code), pub: phone.posted)
        #expect(await until { arrived != nil })
        let check = JoinInvite.check(code: invite.code, publicKey: phone.publicKey)
        #expect(arrived == check)
        #expect(invite.phase == .arrived(check: check))
        #expect(box.envelope(Joining.box(invite.code)) == nil, "nothing sealed before the yes")
        var done = false
        invite.letIn(seal) { done = true }
        #expect(invite.phase == .lettingIn)
        #expect(invite.words == "Letting it in…")
        #expect(await until { done })
        #expect(invite.phase == .letIn)
        #expect(invite.words == "Let in. It has everything in a moment.")
        let envelope = try #require(box.envelope(Joining.box(invite.code)))
        #expect(try phone.open(envelope).raw == seal.raw)
    }

    @MainActor
    @Test func aCodeNobodyScansRunsOutAndOneAnsweredElsewhereFails() async throws {
        let box = PairBox()
        let late = SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: box, timeout: 0.1, every: 0.02))
        late.start { _ in }
        #expect(await until { late.phase == .expired })
        #expect(late.words == "That code ran out. Choose Add a Device for a new one.")
        // Someone answered the box already: not this Mac's device.
        let taken = SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: box, every: 0.02))
        box.post(Joining.box(taken.code), pub: Joining(code: taken.code).posted, envelope: Data([1, 2, 3]))
        taken.start { _ in }
        #expect(await until { taken.phase == .failed })
        // Closed: nothing more is heard.
        let closed = SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: box, every: 0.02))
        var heard = false
        closed.start { _ in heard = true }
        closed.stop()
        box.post(Joining.box(closed.code), pub: Joining(code: closed.code).posted)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!heard)
        #expect(closed.phase == .waiting)
    }

    // MARK: - A server that lies

    @Test func theServerSeesNeitherTheCodeNorAPlainHashOfIt() {
        let code = "K7QM-4XTD"
        let plain = SHA256.hash(data: Data("K7QM4XTD".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(Joining.box(code) != plain)
        #expect(Joining.box(code) == Joining.box("k7qm 4xtd"))
        #expect(Joining.box(code).count == 64)
        let joining = Joining(code: code)
        #expect(Joining.verified(joining.posted, code: "k7qm-4xtd") == joining.publicKey)
        #expect(Joining.verified(joining.publicKey.base64EncodedString(), code: code) == nil, "a bare key, as an older Yab posts")
        #expect(Joining.verified(Joining(code: "ZZZZ-ZZZZ").posted, code: code) == nil, "tagged for another code")
        #expect(Joining.verified(nil, code: code) == nil)
    }

    @MainActor
    @Test func aKeySwappedInUnderTheMacsCodeIsNeverAskedAbout() async throws {
        let box = PairBox()
        let invite = SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: box, every: 0.02))
        var arrived: String?
        invite.start { arrived = $0 }
        // The server knows the box's name, not the code: the key it puts
        // there can't carry the code's tag.
        box.post(Joining.box(invite.code), pub: Joining(code: "ZZZZ-ZZZZ").posted)
        #expect(await until { invite.phase == .failed })
        #expect(arrived == nil)
        #expect(box.envelope(Joining.box(invite.code)) == nil)
    }

    @Test func aMacTypingACodeSealsOnlyToAKeyTheCodeTagged() async throws {
        let base = URL(string: "https://sync.test")!
        let code = "K7QM-4XTD"
        for posted in [Joining(code: code).publicKey.base64EncodedString(), Joining(code: "ZZZZ-ZZZZ").posted] {
            let box = PairBox()
            box.post(Joining.box(code), pub: posted)
            let ok = await withCheckedContinuation { done in
                Pairing.answer(code: code, seal: Seal.make(), base: base, transport: box) { done.resume(returning: $0) }
            }
            #expect(!ok)
            #expect(box.envelope(Joining.box(code)) == nil)
        }
        let box = PairBox()
        let joining = Joining(code: code)
        box.post(Joining.box(code), pub: joining.posted)
        let seal = Seal.make()
        let ok = await withCheckedContinuation { done in
            Pairing.answer(code: "k7qm4xtd", seal: seal, base: base, transport: box) { done.resume(returning: $0) }
        }
        #expect(ok)
        let envelope = try #require(box.envelope(Joining.box(code)))
        #expect(try joining.open(envelope).raw == seal.raw)
    }

    // MARK: - A Mac joining by another Mac's code (register 1628)

    /// The code a syncing Mac shows under Add a Device, typed on a new Mac:
    /// the new Mac posts its key under it, both show the same digits, and
    /// it gets the account's key on the syncing Mac's yes.
    @MainActor
    @Test func aNewMacTypingTheCodeAnotherMacShowsIsLetInAfterTheDigits() async throws {
        let box = PairBox()
        let seal = Seal.make()
        let invite = SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: box, every: 0.02))
        var arrived: String?
        invite.start { arrived = $0 }
        // Typed the way people type it: lower case, a space for the dash.
        let typed = invite.code.lowercased().replacingOccurrences(of: "-", with: " ")
        let code = try #require(JoinInvite.code(scanned: typed))
        let mac = Joining(code: code)
        let got = Got()
        Pairing.wait(mac, base: URL(string: "https://sync.test")!, transport: box, every: 0.02) { got.set($0) }
        #expect(await until { arrived != nil })
        #expect(arrived == JoinInvite.check(code: code, publicKey: mac.publicKey), "both Macs show the same digits")
        #expect(got.value == nil, "nothing before the yes")
        invite.letIn(seal)
        #expect(await until { got.value != nil })
        #expect(try got.value?.get().raw == seal.raw)
    }

    /// A wait under a code outlasts a moment with no network and the
    /// server turning the address away for a while: before, one failed read
    /// ended it and the code typed on the other Mac found nobody.
    @Test func aWaitingMacOutlastsAMomentWithoutNetwork() async throws {
        let base = URL(string: "https://sync.test")!
        let box = Flaky(PairBox(), failing: 6)
        let joining = Joining()
        let got = Got()
        Pairing.wait(joining, base: base, transport: box, every: 0.01) { got.set($0) }
        let seal = Seal.make()
        var answered = false
        for _ in 0..<200 where !answered {
            try await Task.sleep(for: .milliseconds(20))
            answered = await withCheckedContinuation { done in
                Pairing.answer(code: joining.code.lowercased(), seal: seal, base: base, transport: box, retry: 0.01) { done.resume(returning: $0) }
            }
        }
        #expect(answered)
        #expect(await until { got.value != nil })
        #expect(try got.value?.get().raw == seal.raw)
        #expect(box.failed >= 6)
    }

    /// Cancel, or the page gone: nothing more is read, so waits left behind
    /// don't add up to the server's limit for the house's address.
    @Test func aCancelledWaitStopsReadingTheBox() async throws {
        let box = Flaky(PairBox(), failing: 0)
        let got = Got()
        let asking = Pairing.wait(Joining(), base: URL(string: "https://sync.test")!, transport: box, every: 0.01) { got.set($0) }
        #expect(await until { box.requests > 3 })
        asking.cancel()
        try await Task.sleep(for: .milliseconds(100))
        let after = box.requests
        try await Task.sleep(for: .milliseconds(200))
        #expect(box.requests <= after + 1)
        #expect(got.value == nil)
    }

    /// A code another device took first says so, and a code that ran out says so.
    @Test func aTakenCodeAndAnExpiredOneSayWhy() async throws {
        let base = URL(string: "https://sync.test")!
        let box = PairBox()
        let code = "K7QM-4XTD"
        box.post(Joining.box(code), pub: Joining(code: code).posted)
        let taken = Got()
        Pairing.wait(Joining(code: code), base: base, transport: box, every: 0.01) { taken.set($0) }
        #expect(await until { taken.value != nil })
        #expect(taken.failure == .taken)
        let late = Got()
        Pairing.wait(Joining(), base: base, transport: box, timeout: 0.05, every: 0.01) { late.set($0) }
        #expect(await until { late.value != nil })
        #expect(late.failure == .expired)
    }

    @MainActor
    @Test func aCodeTypedBackIntoItsOwnPageSaysWhereItGoes() throws {
        var approvals = 0
        let adding = SyncDeviceAdding(makeInvite: {
            SyncInvite(host: JoinInviteHost(base: URL(string: "https://sync.test")!, transport: PairBox(), every: 0.02))
        }, approveCode: { _, _ in approvals += 1 })
        adding.start()
        let own = try #require(adding.invite?.code)
        adding.edit(own.lowercased())
        adding.approve()
        #expect(approvals == 0)
        #expect(adding.trouble?.hasPrefix("That’s this Mac’s code") == true)
        adding.stop()
    }

    // MARK: - Settings › Sync on the Mac

    @MainActor
    @Test func devicesSayWhetherTheySyncNowOrWhenTheyLastDid() {
        #expect(SyncPage.seen(now.addingTimeInterval(-30), now: now) == "Syncing now")
        #expect(SyncPage.seen(now.addingTimeInterval(-3 * 3600), now: now).hasPrefix("Last synced "))
        #expect(SyncPage.seen(nil, now: now) == "")
        #expect(SyncPage.spaced("4821") == "4 8 2 1")
        #expect(SyncPhones.isPhone("iPhone18,1") && SyncPhones.isPhone("iPad14,1") && !SyncPhones.isPhone("Mac16,1"))
    }

    @MainActor
    @Test func withdrawingAQuestionResumesItsAwaiter() async {
        let invite = SyncInvite(host: JoinInviteHost(code: "K7QM-4XTD", base: URL(string: "https://sync.test")!, transport: PairBox()))
        var question = Question(title: "Add a Device", detail: "Scan or type a code", glyph: "laptopcomputer", yes: "Let In",
                                place: .settings, field: Question.Field("", prompt: "ABCD-EFGH"))
        question.accessory = AnyView(InviteCode(invite: invite))
        #expect(question.width == 420)
        #expect(invite.link == "yab://join/K7QM-4XTD")
        // A queue of its own, not the app's: a device arriving withdraws the
        // card, up or still waiting behind another.
        _ = NSApplication.shared
        let questions = Questions()
        let asked = Task { await questions.ask(question) }
        #expect(await until { questions.current?.id == question.id })
        questions.withdraw(question.id)
        #expect(await asked.value == false)
        let first = Question(title: "First", yes: "OK", place: .settings), second = Question(title: "Second", yes: "OK", place: .settings)
        let up = Task { await questions.ask(first) }
        #expect(await until { questions.current?.id == first.id })
        let waiting = Task { await questions.ask(second) }
        try? await Task.sleep(for: .milliseconds(50))
        questions.withdraw(second.id)
        #expect(await waiting.value == false)
        #expect(questions.current?.id == first.id)
        questions.answer(true)
        #expect(await up.value)
    }

    /// Long enough for the code's stretch (PBKDF2) on a Mac running a
    /// thousand tests at once.
    private func until(_ seconds: Double = 30, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }
}
/// The server's pairing box, in memory: POST, GET and PUT as sync-server's.
final class PairBox: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var boxes: [String: (pub: String, envelope: String?)] = [:]

    func post(_ box: String, pub: String, envelope: Data? = nil) {
        lock.lock(); defer { lock.unlock() }
        boxes[box] = (pub, envelope?.base64EncodedString())
    }

    func envelope(_ box: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return boxes[box]?.envelope.flatMap { Data(base64Encoded: $0) }
    }

    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
        lock.lock()
        let path = request.url?.path ?? ""
        let json = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        var status = 404
        var body: [String: Any] = [:]
        if path == "/v1/pair", request.httpMethod == "POST", let code = json?["code"] as? String, let pub = json?["pub"] as? String {
            if boxes[code] != nil { status = 409 } else { boxes[code] = (pub, nil); status = 204 }
        } else if path.hasPrefix("/v1/pair/") {
            let code = String(path.dropFirst("/v1/pair/".count))
            if let box = boxes[code] {
                if request.httpMethod == "PUT", let envelope = json?["envelope"] as? String {
                    if box.envelope != nil { status = 409 } else { boxes[code]?.envelope = envelope; status = 204 }
                } else {
                    status = 200
                    body = ["pub": box.pub]
                    if let envelope = box.envelope { body["envelope"] = envelope }
                }
            }
        }
        lock.unlock()
        DispatchQueue.global().async { done(status, try? JSONSerialization.data(withJSONObject: body)) }
    }

    final class Silent: Line {
        func send(_ text: String) {}
        func close() {}
    }

    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line { Silent() }
}

/// What a wait ended with, from any queue.
final class Got: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Seal, Pairing.Failure>?
    func set(_ result: Result<Seal, Pairing.Failure>) { lock.lock(); self.result = result; lock.unlock() }
    var value: Result<Seal, Pairing.Failure>? { lock.lock(); defer { lock.unlock() }; return result }
    var failure: Pairing.Failure? {
        if case let .failure(failure) = value { return failure }
        return nil
    }
}

/// A server whose first `failing` answers never come back (no network),
/// alternating with the door's 429; everything after goes to `inner`.
final class Flaky: Transport, @unchecked Sendable {
    private let inner: PairBox
    private let lock = NSLock()
    private var left: Int
    private(set) var failed = 0
    private var count = 0

    init(_ inner: PairBox, failing: Int) {
        self.inner = inner
        left = failing
    }

    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }

    func request(_ request: URLRequest, _ done: @escaping (Int?, Data?) -> Void) {
        lock.lock()
        count += 1
        let fail = left > 0
        if fail { left -= 1; failed += 1 }
        let status: Int? = failed % 2 == 0 ? 429 : nil
        lock.unlock()
        if fail { return DispatchQueue.global().async { done(status, nil) } }
        inner.request(request, done)
    }

    func open(_ request: URLRequest, received: @escaping (String) -> Void, closed: @escaping (Int?) -> Void) -> Line { PairBox.Silent() }
}

@Suite struct AccountMoveTests {
    @Test func aMoveRecordNamesTheKeyAndIgnoresItsOwn() {
        let here = Seal.make(), there = Seal.make()
        let record = SyncKit.Record(collection: SyncCollection.moved, id: AccountMove.id, fields: AccountMove.fields(to: there))
        #expect(AccountMove.destination([record], from: here)?.raw == there.raw)
        #expect(AccountMove.destination([record], from: there) == nil, "already there")
        let other = SyncKit.Record(collection: SyncCollection.setting, id: AccountMove.id, fields: AccountMove.fields(to: there))
        #expect(AccountMove.destination([other], from: here) == nil)
    }
}
