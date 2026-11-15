import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Fast
@testable import MailCore
import MailCoreFakes
@testable import SyncKit

/// The Mac's side of an approval's details (ApprovalDetails.swift,
/// docs/approvals.md "Details"): what each kind of question publishes, a
/// phone's picks chosen as a click is, a pay sheet's phases as results, and
/// a card the phone keeps read the way Wallet reads its own.
@MainActor
struct ApprovalDetailMacTests {
    private let id = "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10"

    private func request() throws -> AssistantApprovalRecords.Request {
        try AssistantApprovalRecords.Request(
            id: id, account: "account", mac: "mac", assistant: "local.claude", session: "session",
            tab: "0b8f0c3e-5c55-4bd8-8f5e-3cb6f7a1e2d4", permit: "e12", title: "Claude: Pay now · $42.10?",
            lines: ["shop.example", "Amount: $42.10"], issued: Date(), expires: Date().addingTimeInterval(300))
    }

    // MARK: - a payment

    private static let visa = SavedCard(id: "card-visa", number: "4242424242424242", last4: "4242", brand: "Visa", name: "Ann Lee",
                                        month: 8, year: 2031, used: Date(), csc: "123")
    private static let master = SavedCard(id: "card-mc", number: "5555555555554444", last4: "4444", brand: "Mastercard", name: "Ann Lee",
                                          month: 1, year: 2032)

    private static func home() -> StreetAddress {
        var home = StreetAddress(id: "place-home")
        home.name = "Ann Lee"; home.street = "14 Grand St"; home.city = "New York"; home.postal = "10013"; home.source = "Contacts, home"
        home.used = Date()
        return home
    }

    private static func office() -> StreetAddress {
        var office = StreetAddress(id: "place-office")
        office.name = "Ann Lee"; office.street = "300 Broadway"; office.city = "New York"; office.postal = "10007"; office.source = "Contacts, work"
        return office
    }

    /// The sheet as PayFlow makes it, from the stand-in wallet.
    private func sheet() -> PaySheetModel {
        PayWallet.standIn = (cards: [Self.visa, Self.master], addresses: [Self.home(), Self.office()])
        defer { PayWallet.standIn = nil }
        let mine: Set = ["card-visa", "card-mc", "place-home", "place-office"]
        var model = PaySheetModel(site: "shop.example", item: "Oxford Shirt · Navy · M", amount: "$42.10")
        model.cards = PayWallet.cards().filter { mine.contains($0.id) }.map(PaySheetModel.Card.init)
        model.places = PayWallet.addresses().filter { mine.contains($0.id) }.map(PaySheetModel.Place.init)
        model.card = model.cards.first?.id
        model.place = model.places.first?.id
        model.delivery = "Arrives Thursday, Oct 23 · free"
        return model
    }

    @Test func aPaymentSaysTheSheetsCardsAndPlacesNeverANumber() throws {
        let detail = ApprovalDetailBuilder.pay(id: id, sheet())
        try detail.validate(for: request())
        let pay = try #require(detail.pay)
        #expect(detail.verb == "Pay $42.10")
        #expect(pay.site == "shop.example" && pay.item == "Oxford Shirt · Navy · M" && pay.delivery.hasPrefix("Arrives"))
        #expect(pay.cards.map(\.last4) == ["4242", "4444"] && pay.cards.map(\.brand) == ["Visa", "Mastercard"])
        #expect(pay.places.count == 2 && pay.places[0].line.contains("Grand St") && pay.places[1].line.contains("Broadway"))
        #expect(pay.places.map(\.who) == ["Home", "Office"])
        #expect(pay.card == "card-visa" && pay.place == "place-home" && pay.takesCard && pay.takesPlace)
        let body = try #require(try detail.fields()["body"]?.string)
        for secret in ["4242424242424242", "5555555555554444", "\"123\""] { #expect(!body.contains(secret)) }
    }

    @Test func thePaymentsDetailFollowsItsSheet() throws {
        var model = sheet()
        let before = try ApprovalDetailBuilder.pay(id: id, model).digest()
        // The page's total read again: another detail, a yes to the old one refused.
        model.amount = "$47.09"
        let after = ApprovalDetailBuilder.pay(id: id, model)
        let digest = try after.digest()
        #expect(after.verb == "Pay $47.09" && digest != before)
        let old = try AssistantApprovalRecords.Answer(request: request(), device: "phone", yes: true,
                                                      detail: ApprovalDetailBuilder.pay(id: id, sheet()), card: "card-mc")
        #expect(throws: (any Error).self) { try AssistantApprovalRecords.validatePicks(old, detail: after) }
        // A card added on the Mac is offered at once, picked.
        model.added(.init(id: "card-new", brand: "American Express", last4: "1005", name: "Travel"))
        let added = ApprovalDetailBuilder.pay(id: id, model)
        #expect(added.pay?.cards.first?.id == "card-new" && added.pay?.card == "card-new")
        // A page without card boxes says so: the phone offers no pick.
        model.takesCard = false
        #expect(ApprovalDetailBuilder.pay(id: id, model).pay?.takesCard == false)
    }

    @Test func aPickFromThePhoneIsChosenAsAClickInTheListIs() throws {
        var model = sheet()
        let card = model.choose(card: "card-mc")
        #expect(card && model.card == "card-mc" && model.cardPicked && model.pane == .main)
        let place = model.choose(place: "place-office")
        #expect(place && model.place == "place-office" && model.placePicked && model.pane == .main)
        let gone = model.choose(card: "card-gone")
        #expect(!gone && model.card == "card-mc")
        // Picked again where it already is: nothing new is picked.
        var same = sheet()
        let again = same.choose(card: "card-visa")
        #expect(again && !same.cardPicked)
        // A page with no card boxes, or a sheet paying: the list doesn't open.
        var closed = sheet()
        closed.takesCard = false
        let shut = closed.choose(card: "card-mc")
        #expect(!shut && closed.card == "card-visa")
        var paying = sheet()
        paying.phase = .paying
        let locked = paying.choose(place: "place-office")
        #expect(!locked)
        // The answer that names them passes the Mac's check against the detail.
        let detail = ApprovalDetailBuilder.pay(id: id, sheet())
        let kept = UUID().uuidString
        let answer = try AssistantApprovalRecords.Answer(request: request(), device: "phone", yes: true, detail: detail,
                                                         card: kept, place: "place-office", added: [kept])
        try AssistantApprovalRecords.validatePicks(answer, detail: detail)
        #expect(AssistantApprovals.Picks(answer) == .init(card: kept, place: "place-office", added: [kept], at: answer.at))
    }

    @Test func thePaySheetsPhasesAreWhatCameOfTheYes() {
        #expect(ApprovalDetailBuilder.result(id: id, phase: .ready, order: "") == nil)
        #expect(ApprovalDetailBuilder.result(id: id, phase: .checking, order: "") == nil)
        #expect(ApprovalDetailBuilder.result(id: id, phase: .armed, order: "") == nil)
        #expect(ApprovalDetailBuilder.result(id: id, phase: .paying, order: "")?.phase == .paying)
        let paid = ApprovalDetailBuilder.result(id: id, phase: .paid, order: "112-4471")
        #expect(paid?.phase == .paid && paid?.order == "112-4471" && paid?.settled == true)
        #expect(ApprovalDetailBuilder.result(id: id, phase: .paid, order: "")?.order == nil)
        let declined = ApprovalDetailBuilder.result(id: id, phase: .declined, order: "")
        #expect(declined?.phase == .declined && declined?.words == "Payment not completed")
        // Every send's failure in a word or two, nothing of the error.
        let mail = AgentPermit(kind: .sendMail(to: "Anna", mail: "k"), session: "s", detail: "")
        #expect(ApprovalDetails.failure(mail) == "Not sent")
        #expect(ApprovalDetails.failure(AgentPermit(kind: .upload(files: [], ref: "e1"), session: "s", detail: "")) == "Not uploaded")
    }

    // MARK: - mail

    private static let anna = MailPerson(name: "Anna Lindqvist", address: "anna@fold.studio")

    @Test func mailsTravelWholeWithEveryAddressAndTheirFilesFirstPages() async throws {
        let (store, gmail, _) = MailWorld.make(host: "approval-\(UUID().uuidString.prefix(8)).test")
        let engine = MailCenter.Engine(account: "me@example.com", store: store, gmail: gmail, sync: MailSync(store: store, gmail: gmail))
        let words = String(repeating: "The venue moved to the second floor, room 4. ", count: 30)
        #expect(words.count > 600)
        var draft = MailDraft(to: [Self.anna], cc: [.init(name: "", address: "tim@fold.studio")],
                              bcc: [.init(name: "Ledger", address: "ledger@example.com")], subject: "Venue", body: words)
        draft.files = MailAttach.take([try Self.pdf(pages: 4), try Self.picture(width: 2400, height: 1600)], draft: draft.id, store: store)
        #expect(draft.files.count == 2)
        let out = MailAgent.Outgoing(engine: engine, draft: draft, ready: nil)

        let built = ApprovalDetailBuilder.mails(id: id, [out])
        try built.detail.validate(for: request())
        #expect(built.detail.verb == "Send")
        let mail = try #require(built.detail.mails?.first)
        #expect(mail.body == words, "the whole body, not the card's 600 characters")
        #expect(mail.from?.address == "me@example.com")
        #expect(mail.to == [.init(name: "Anna Lindqvist", address: "anna@fold.studio")])
        #expect(mail.cc.map(\.address) == ["tim@fold.studio"] && mail.bcc?.map(\.address) == ["ledger@example.com"])
        #expect(mail.files.map(\.kind) == ["pdf", "image"])
        #expect(mail.files[0].pages == 4 && mail.files[0].previews == 3 && mail.files[1].previews == 1)
        #expect(mail.files[1].width == 2400 && mail.files[1].height == 1600)
        #expect(built.pictured.map(\.pages) == [3, 1])
        for pictured in built.pictured {
            let pages = await Task.detached { ApprovalDetailBuilder.pictures(of: pictured) }.value
            #expect(pages.count == pictured.pages)
            for jpeg in pages {
                #expect(jpeg.count <= ApprovalDetailBuilder.jpegLimit && jpeg.prefix(2) == Data([0xFF, 0xD8]))
                try Self.fitsARecord(jpeg, file: pictured.file)
            }
        }

        // Three at once: one yes, Send All 3, nobody named alone.
        let three = ApprovalDetailBuilder.mails(id: id, [out, out, out]).detail
        #expect(three.verb == "Send All 3" && three.mails?.count == 3 && three.person == nil)
        let plain = MailAgent.Outgoing(engine: engine, draft: MailDraft(to: [Self.anna], subject: "Hi", body: "Hi."), ready: nil)
        #expect(ApprovalDetailBuilder.mails(id: id, [plain]).detail.person?.address == "anna@fold.studio")
    }

    @Test func aMailTooLongForItsRecordIsCutToFit() throws {
        let huge = String(repeating: "Lorem ipsum dolor sit amet. ", count: 8_000)
        let detail = ApprovalDetailBuilder.fitted(.init(id: id, verb: "Send", mails: [
            .init(id: "a", to: [.init(name: "Anna")], subject: "Long", body: huge),
            .init(id: "b", to: [.init(name: "Tim")], subject: "Short", body: "Short words."),
        ]))
        try detail.validate(for: request())
        let size = try detail.fields()["body"]?.string?.utf8.count ?? .max
        #expect(size <= ApprovalDetailBuilder.room)
        #expect(detail.mails?[0].body.hasSuffix("…") == true && detail.mails?[1].body == "Short words.")
    }

    // MARK: - files

    @Test func aMailSearchSaysItsFirstLookAndTheTermsForTheChat() throws {
        let permit = AgentPermit(kind: .mailRead, session: "searcher", detail: "Looks for \u{201C}Yab 0.32\u{201D}. Claude reads it.")
        let key = ApprovalDetails.changeKey(session: "searcher", permit: permit)
        ApprovalDetails.shared.searching[key] = "Looks for \u{201C}Yab 0.32\u{201D}\nClaude reads it."
        defer { ApprovalDetails.shared.searching[key] = nil }
        let detail = ApprovalDetailBuilder.build(id: id, permit: permit, tab: nil).detail
        #expect(detail.verb == "Allow in This Chat")
        #expect(detail.text == "Looks for \u{201C}Yab 0.32\u{201D}\nClaude reads it.")
        try detail.validate(for: request())
    }

    @Test func anUploadPicturesItsFiles() async throws {
        let passport = try Self.pdf(pages: 8, named: "passport.pdf")
        let one = ApprovalDetailBuilder.upload(id: id, [passport])
        #expect(one.detail.verb == "Upload passport.pdf")
        #expect(one.detail.files?.first?.pages == 8 && one.detail.files?.first?.previews == 6)
        let two = ApprovalDetailBuilder.upload(id: id, [passport, try Self.picture(width: 3000, height: 2000)])
        try two.detail.validate(for: request())
        #expect(two.detail.verb == "Upload 2 Files" && two.detail.files?.map(\.id) == ["f0", "f1"])
        #expect(two.pictured.map(\.pages) == [6, 1])
        // Noise is the worst a camera gives: still within the record.
        let image = try #require(two.pictured.last)
        let pages = await Task.detached { ApprovalDetailBuilder.pictures(of: image) }.value
        let jpeg = try #require(pages.first)
        #expect(jpeg.count <= ApprovalDetailBuilder.jpegLimit)
        try Self.fitsARecord(jpeg, file: image.file)
    }

    /// The preview's sealed record as it goes up is within the server's
    /// 96 KB a record (sync-server MAX_BLOB).
    private static func fitsARecord(_ jpeg: Data, file: String) throws {
        let preview = try AssistantApprovalRecords.Preview(request: "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a10", file: file, page: 0, jpeg: jpeg)
        let record = Record(collection: AssistantApprovalRecords.previewCollection, id: preview.id, fields: try preview.fields(),
                            stamps: ["body": Stamp(wall: 1_760_000_000_000, device: "mac-device-id-0000000000000000")])
        let sealed = try Seal(key: SymmetricKey(size: .bits256)).seal(record)
        #expect(sealed.base64EncodedString().count <= 96 * 1024)
    }

    // MARK: - a card kept on the phone

    @Test func aCardKeptOnThePhoneIsReadAsWalletReadsItsOwn() throws {
        let seal = Seal(key: SymmetricKey(size: .bits256))
        let cid = UUID().uuidString
        let fields = try AssistantWallet.card(id: cid, number: "3782 822463 10005", csc: "1234", name: "Ann Lee", month: 8, year: 2029, seal: seal)
        // As SyncWallet.write puts it into the keychain: the facts as JSON,
        // the secret opened; and as Wallet.cards() and number(of:) read it back.
        let generic = try JSONEncoder().encode(try #require(fields["facts"]))
        let facts = try #require(try JSONSerialization.jsonObject(with: generic) as? [String: Any])
        let card = Wallet.card(id: cid, facts: facts)
        #expect(card.last4 == "0005" && card.brand == "American Express" && card.name == "Ann Lee")
        #expect(card.month == 8 && card.year == 2029 && card.keepsCode && card.source == "Yab for iPhone")
        let secret = try #require(fields["secret"]?.string.flatMap { seal.reveal($0, in: .init(collection: SyncCollection.card, id: cid)) })
        #expect(Wallet.secret(of: secret).number == "378282246310005" && Wallet.secret(of: secret).code == "1234")
        #expect(PaySheetModel.Card(card).title == "Amex •••• 0005")

        let aid = UUID().uuidString
        let place = try AssistantWallet.address(id: aid, name: "Ann Lee", street: "1 Main St\nApt 4", city: "Brooklyn", postal: "11201", seal: seal)
        let plain = try #require(place["secret"]?.string.flatMap { seal.reveal($0, in: .init(collection: SyncCollection.address, id: aid)) })
        let address = try #require(Wallet.address(of: plain))
        #expect(address.id == aid && address.line1 == "1 Main St" && address.city == "Brooklyn" && address.postal == "11201")
        #expect(PaySheetModel.Place(address.tidied()).line.hasPrefix("1 Main St") && address.whole)
    }

    // MARK: - files to picture

    static func pdf(pages: Int, named name: String = "deck.pdf") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 72, y: 72 + CGFloat(page) * 30, width: 300, height: 200))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Noise, as hard as a picture gets to make small.
    static func picture(width: Int, height: Int) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("photo.png")
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 7
        for i in 0..<(width * height * 4) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
        }
        let image = try #require(context.makeImage())
        let sink = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(sink, image, nil)
        #expect(CGImageDestinationFinalize(sink))
        return url
    }
}
