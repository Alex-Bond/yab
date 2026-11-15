import CryptoKit
import Foundation
import Testing
@testable import Fast
@testable import SyncKit

/// What an approval is about, read whole on another device before its yes
/// (AssistantApprovalDetails.swift, docs/approvals.md "Details").
struct ApprovalDetailTests {
    private let id = "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10"

    private func request() throws -> AssistantApprovalRecords.Request {
        try AssistantApprovalRecords.Request(
            id: id, account: "account", mac: "mac", assistant: "local.claude", session: "session",
            tab: "0b8f0c3e-5c55-4bd8-8f5e-3cb6f7a1e2d4", permit: "press:pay", title: "Claude: Pay $42.10?",
            lines: ["amazon.com", "Amount: $42.10"], issued: Date(), expires: Date().addingTimeInterval(300))
    }

    private func pay() -> AssistantApprovalRecords.Detail {
        .init(id: id, verb: "Pay $42.10", pay: .init(
            site: "amazon.com", item: "AirPods Pro ear tips · 2 items", amount: "$42.10", delivery: "Arrives Thursday",
            cards: [.init(id: "c1", brand: "Visa", last4: "6411", name: "Chase"), .init(id: "c2", brand: "American Express", last4: "1005", name: "Amex")],
            places: [.init(id: "p1", line: "14 Grand St, New York", who: "Home")],
            card: "c1", place: "p1", takesCard: true, takesPlace: true))
    }

    private func record(_ collection: String, _ id: String, _ fields: [String: Value], by device: String) -> Record {
        Record(collection: collection, id: id, fields: fields, stamps: ["body": Stamp(wall: 1, device: device)])
    }

    @Test func anAnswerFromBeforeDetailsEncodesAsVersionTwo() throws {
        let request = try request()
        let answer = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true, proved: true)
        let body = try #require(answer.fields()["body"]?.string)
        for key in ["detailDigest", "card", "place", "added"] { #expect(!body.contains("\"\(key)\"")) }
        // An old answer to a request that has a detail still counts: it read the lines.
        try AssistantApprovalRecords.validatePicks(answer, detail: pay())
    }

    @Test func aDetailTravelsAndReadsBack() throws {
        let request = try request()
        let detail = pay()
        let read = try AssistantApprovalRecords.Detail.read(
            record(AssistantApprovalRecords.detailCollection, id, try detail.fields(), by: "mac"), request: request)
        #expect(read == detail)
        // Written by someone else than the asking Mac: refused.
        #expect(throws: (any Error).self) {
            _ = try AssistantApprovalRecords.Detail.read(
                record(AssistantApprovalRecords.detailCollection, id, try detail.fields(), by: "phone"), request: request)
        }
        // A picked card the lists don't have: refused.
        var wrong = detail
        wrong.pay?.card = "c9"
        #expect(throws: (any Error).self) { try wrong.validate(for: request) }
    }

    @Test func aYesPicksAmongTheDetailOrWhatItJustKept() throws {
        let request = try request()
        let detail = pay()
        let ok = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true, proved: true,
                                                     detail: detail, card: "c2", place: "p1")
        #expect(ok.detailDigest == (try detail.digest()) && ok.card == "c2")
        let kept = UUID().uuidString
        _ = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true, detail: detail,
                                                card: kept, added: [kept])
        for (card, place) in [("c9", nil), (nil, "p9")] as [(String?, String?)] {
            #expect(throws: (any Error).self) {
                _ = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true, detail: detail, card: card, place: place)
            }
        }
        // The detail changed after the phone read it: the Mac refuses the yes.
        var changed = detail
        changed.pay?.amount = "$99.00"
        #expect(throws: (any Error).self) { try AssistantApprovalRecords.validatePicks(ok, detail: changed) }
        // A page without card boxes takes no pick.
        var noBoxes = detail
        noBoxes.pay?.takesCard = false
        #expect(throws: (any Error).self) {
            _ = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true, detail: noBoxes, card: "c2")
        }
        // A no picks nothing.
        let no = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: false, detail: detail, card: "c2")
        #expect(no.card == nil && no.added == nil)
    }

    @Test func previewsAndResultsComeOnlyFromTheMac() throws {
        let request = try request()
        let jpeg = Data(repeating: 0xFF, count: 2_000)
        let preview = try AssistantApprovalRecords.Preview(request: id, file: "f1", page: 0, jpeg: jpeg)
        let pid = AssistantApprovalRecords.Preview.id(request: id, file: "f1", page: 0)
        let back = try AssistantApprovalRecords.Preview.read(record(AssistantApprovalRecords.previewCollection, pid, try preview.fields(), by: "mac"),
                                                             request: request, file: "f1", page: 0)
        #expect(back.data == jpeg)
        #expect(throws: (any Error).self) {
            _ = try AssistantApprovalRecords.Preview(request: id, file: "f1", page: 0, jpeg: Data(count: 60_000))
        }
        let result = AssistantApprovalRecords.Result(id: id, phase: .paid, order: "#112-4836027")
        let read = try AssistantApprovalRecords.Result.read(record(AssistantApprovalRecords.resultCollection, id, try result.fields(), by: "mac"),
                                                            request: request)
        #expect(read.phase == .paid && read.order == "#112-4836027" && read.settled)
        #expect(throws: (any Error).self) {
            _ = try AssistantApprovalRecords.Result.read(record(AssistantApprovalRecords.resultCollection, id, try result.fields(), by: "phone"),
                                                         request: request)
        }
    }

    @Test func aCardKeptOnThePhoneIsWhatWalletKeeps() throws {
        let seal = Seal(key: SymmetricKey(size: .bits256))
        let cid = UUID().uuidString
        let fields = try AssistantWallet.card(id: cid, number: "4242 4242 4242 4242", csc: "123", name: "Sam R", month: 8, year: 2029, seal: seal)
        let opened = try #require(fields["secret"]?.string.flatMap { seal.reveal($0, in: .init(collection: SyncCollection.card, id: cid)) })
        let secret = try #require(JSONSerialization.jsonObject(with: opened) as? [String: String])
        #expect(secret == ["number": "4242424242424242", "csc": "123"])
        #expect(fields["facts"]?.object?["last4"] == .string("4242") && fields["facts"]?.object?["brand"] == .string("Visa"))
        #expect(throws: (any Error).self) {
            _ = try AssistantWallet.card(id: cid, number: "4242 4242 4242 4241", csc: "", name: "", month: 8, year: 2029, seal: seal)
        }
        let aid = UUID().uuidString
        let place = try AssistantWallet.address(id: aid, name: "Sam", street: "1 Main St\nApt 4", city: "Brooklyn", postal: "11201", seal: seal)
        let plain = try #require(place["secret"]?.string.flatMap { seal.reveal($0, in: .init(collection: SyncCollection.address, id: aid)) })
        // The Mac's Wallet reads it as a StreetAddress.
        let address = try JSONDecoder().decode(StreetAddress.self, from: plain)
        #expect(address.line1 == "1 Main St" && address.city == "Brooklyn" && address.postal == "11201")
    }
}
