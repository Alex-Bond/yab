import CryptoKit
import Foundation

// What an approval is about, whole, for a device that reads before it says
// yes (docs/approvals.md, "Details"). The request keeps its short lines and
// its digest as they were, so a device from before reads and answers it as
// ever; the whole thing travels beside it in records of its own:
//
// - `assistantdetail`, the request's id: the mails as they will go, the
//   files, a payment's cards and addresses, a post's or a message's words.
// - `assistantpreview`, "<request>.<file>.<page>": one small JPEG of a
//   file's page, so the detail stays small and a page comes when it does.
// - `assistantresult`, the request's id: what came of a yes, paying on the
//   site, paid with its order, declined, done or failed, for the device
//   that answered to keep showing it until the site has said.
//
// An answer from a device that read the detail names its digest, and a
// payment's yes names the card and the address picked there, one of the
// detail's or one this device just kept (a `card` or `address` record of
// its own, SyncWallet's shape, `AssistantWallet`).
extension AssistantApprovalRecords {
    public static let detailCollection = "assistantdetail"
    public static let previewCollection = "assistantpreview"
    public static let resultCollection = "assistantresult"
    /// A detail's encoded body; a preview's base64 JPEG.
    static let detailLimit = 60_000
    static let previewLimit = 72_000

    /// Version 3 reads details and previews, picks a payment's card and
    /// address, and shows results.
    public static let detailVersion = 3

    /// A device that reads details and picks (commandcap version 3).
    public static func reads(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability, record.id == device, record.alive(),
              record.stamps[field]?.device == device, let said = record[field]?.number else { return false }
        return said >= Double(detailVersion)
    }

    public static func registerDetails() {
        Kind.register(Kind(detailCollection, removalWins: true))
        Kind.register(Kind(previewCollection, removalWins: true))
        Kind.register(Kind(resultCollection, removalWins: true))
    }

    // MARK: - the detail

    public struct Detail: Codable, Equatable, Sendable {
        public struct Person: Codable, Equatable, Sendable {
            public var name: String
            public var address: String?
            public init(name: String, address: String? = nil) { self.name = name; self.address = address }
        }

        /// A file as it is named and measured; its pages' pictures are
        /// `previews` records, 0..<previews.
        public struct File: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            public var name: String
            public var bytes: Int?
            /// "pdf", "image" or "file".
            public var kind: String
            public var pages: Int?
            public var width: Int?
            public var height: Int?
            public var previews: Int
            public init(id: String, name: String, bytes: Int? = nil, kind: String, pages: Int? = nil,
                        width: Int? = nil, height: Int? = nil, previews: Int = 0) {
                self.id = id; self.name = name; self.bytes = bytes; self.kind = kind; self.pages = pages
                self.width = width; self.height = height; self.previews = previews
            }
        }

        public struct Mail: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            public var from: Person?
            public var to: [Person]
            public var cc: [Person]
            /// Whom it goes to unseen by the others; absent when nobody, so
            /// a mail without one encodes, and digests, as before.
            public var bcc: [Person]?
            public var subject: String
            public var body: String
            public var files: [File]
            /// For mail being changed rather than sent: when it came.
            public var date: Double?
            public init(id: String, from: Person? = nil, to: [Person], cc: [Person] = [], bcc: [Person]? = nil, subject: String,
                        body: String, files: [File] = [], date: Double? = nil) {
                self.id = id; self.from = from; self.to = to; self.cc = cc; self.bcc = bcc; self.subject = subject
                self.body = body; self.files = files; self.date = date
            }
        }

        public struct Card: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            /// As Wallet names it: "Visa", "Mastercard", "American Express".
            public var brand: String
            public var last4: String
            public var name: String
            public init(id: String, brand: String, last4: String, name: String) {
                self.id = id; self.brand = brand; self.last4 = last4; self.name = name
            }
        }

        public struct Place: Codable, Equatable, Sendable, Identifiable {
            public var id: String
            /// "14 Grand St, New York".
            public var line: String
            /// "Home", "Office", a name.
            public var who: String
            public init(id: String, line: String, who: String) { self.id = id; self.line = line; self.who = who }
        }

        /// A payment as the Mac's pay sheet has it (PaySheetModel).
        public struct Pay: Codable, Equatable, Sendable {
            public var site: String
            public var item: String
            public var amount: String
            public var delivery: String
            public var cards: [Card]
            public var places: [Place]
            public var card: String?
            public var place: String?
            /// The page has boxes for a card, an address: a pick can go in.
            public var takesCard: Bool
            public var takesPlace: Bool
            public init(site: String, item: String, amount: String, delivery: String = "", cards: [Card] = [],
                        places: [Place] = [], card: String? = nil, place: String? = nil,
                        takesCard: Bool = false, takesPlace: Bool = false) {
                self.site = site; self.item = item; self.amount = amount; self.delivery = delivery
                self.cards = cards; self.places = places; self.card = card; self.place = place
                self.takesCard = takesCard; self.takesPlace = takesPlace
            }
        }

        public var id: String
        /// The yes in words: "Send All 3", "Pay $42.10", "Upload 2 Files".
        public var verb: String?
        public var mails: [Mail]?
        public var files: [File]?
        public var pay: Pay?
        /// A post's, a message's whole words.
        public var text: String?
        /// Whom a message or a mail is to, when it is one person.
        public var person: Person?

        public init(id: String, verb: String? = nil, mails: [Mail]? = nil, files: [File]? = nil, pay: Pay? = nil,
                    text: String? = nil, person: Person? = nil) {
            self.id = id; self.verb = verb; self.mails = mails; self.files = files; self.pay = pay
            self.text = text; self.person = person
        }

        public var allFiles: [File] { (files ?? []) + (mails ?? []).flatMap(\.files) }

        public func validate(for request: Request) throws {
            let files = allFiles
            guard id.lowercased() == request.id.lowercased(),
                  (verb?.count ?? 0) <= 60,
                  (mails?.count ?? 0) <= 20, files.count <= 20,
                  files.allSatisfy({ ["pdf", "image", "file"].contains($0.kind) && (0...12).contains($0.previews)
                      && !$0.id.isEmpty && $0.id.utf8.count <= 64 && !$0.id.contains(".") }),
                  Set(files.map(\.id)).count == files.count,
                  pay.map({ p in p.cards.count <= 12 && p.places.count <= 12
                      && Set(p.cards.map(\.id)).count == p.cards.count
                      && Set(p.places.map(\.id)).count == p.places.count
                      && (p.card.map { id in p.cards.contains { $0.id == id } } ?? true)
                      && (p.place.map { id in p.places.contains { $0.id == id } } ?? true) }) ?? true,
                  try encoded().utf8.count <= AssistantApprovalRecords.detailLimit else { throw Failure.invalid }
        }

        /// What a yes that read this is bound to.
        public func digest() throws -> String {
            let bytes = Data(("yab assistant detail v1\n" + (try encoded())).utf8)
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }

        public func fields() throws -> [String: Value] { ["body": .string(try encoded())] }

        public static func read(_ record: Record, request: Request) throws -> Detail {
            let detail: Detail = try AssistantApprovalRecords.decodeBody(record, collection: detailCollection, writer: request.mac,
                                                                           limit: detailLimit)
            guard record.id.lowercased() == request.id.lowercased() else { throw Failure.owner }
            try detail.validate(for: request)
            return detail
        }

        func encoded() throws -> String { try AssistantApprovalRecords.encodeBody(self) }
    }

    // MARK: - a page's picture

    public struct Preview: Codable, Equatable, Sendable {
        public var id: String
        /// JPEG, base64.
        public var jpeg: String

        public init(request: String, file: String, page: Int, jpeg: Data) throws {
            id = Self.id(request: request, file: file, page: page)
            self.jpeg = jpeg.base64EncodedString()
            guard self.jpeg.utf8.count <= AssistantApprovalRecords.previewLimit else { throw Failure.invalid }
        }

        public static func id(request: String, file: String, page: Int) -> String {
            "\(request.lowercased()).\(file).\(page)"
        }

        public var data: Data? { Data(base64Encoded: jpeg) }

        public func fields() throws -> [String: Value] { ["body": .string(try AssistantApprovalRecords.encodeBody(self))] }

        public static func read(_ record: Record, request: Request, file: String, page: Int) throws -> Preview {
            let preview: Preview = try AssistantApprovalRecords.decodeBody(record, collection: previewCollection, writer: request.mac,
                                                                             limit: previewLimit + 400)
            guard preview.id == id(request: request.id, file: file, page: page), record.id == preview.id,
                  preview.jpeg.utf8.count <= previewLimit else { throw Failure.owner }
            return preview
        }
    }

    // MARK: - what came of it

    public struct Result: Codable, Equatable, Sendable {
        public enum Phase: String, Codable, Sendable {
            /// The site is being pressed (a payment).
            case paying
            case paid
            case declined
            /// Anything else that went as asked: sent, uploaded, signed in.
            case done
            case failed
        }

        public var id: String
        public var phase: Phase
        /// Short words for what happened: "Payment not completed".
        public var words: String?
        /// The site's name for the order, when it said one.
        public var order: String?
        public var at: Double

        public init(id: String, phase: Phase, words: String? = nil, order: String? = nil, at: Date = Date()) {
            self.id = id; self.phase = phase; self.words = words; self.order = order; self.at = at.timeIntervalSince1970
        }

        public var settled: Bool { phase != .paying }

        public func fields() throws -> [String: Value] { ["body": .string(try AssistantApprovalRecords.encodeBody(self))] }

        public static func read(_ record: Record, request: Request) throws -> Result {
            let result: Result = try AssistantApprovalRecords.decodeBody(record, collection: resultCollection, writer: request.mac,
                                                                           limit: 4_000)
            guard result.id.lowercased() == request.id.lowercased(), record.id.lowercased() == request.id.lowercased(),
                  (result.words?.count ?? 0) <= 200, (result.order?.count ?? 0) <= 80, result.at.isFinite else { throw Failure.owner }
            return result
        }
    }

    // MARK: - an answer's picks

    /// A payment's picks, checked against the detail the yes was given to.
    /// `added`: ids of the `card` and `address` records the answering device
    /// kept just now, which the detail can't list yet.
    public static func validatePicks(_ answer: Answer, detail: Detail?) throws {
        guard answer.detailDigest != nil || (answer.card == nil && answer.place == nil && answer.added == nil) else {
            throw Failure.changed
        }
        guard let detail else {
            if answer.detailDigest != nil { throw Failure.changed }
            return
        }
        if let digest = answer.detailDigest, digest != (try detail.digest()) { throw Failure.changed }
        guard answer.yes || (answer.card == nil && answer.place == nil && answer.added == nil) else { throw Failure.changed }
        let added = Set(answer.added ?? [])
        guard added.count <= 2, added.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw Failure.changed }
        if let card = answer.card {
            guard let pay = detail.pay, pay.takesCard, pay.cards.contains(where: { $0.id == card }) || added.contains(card)
            else { throw Failure.changed }
        }
        if let place = answer.place {
            guard let pay = detail.pay, pay.takesPlace, pay.places.contains(where: { $0.id == place }) || added.contains(place)
            else { throw Failure.changed }
        }
    }

    // MARK: - body coding, shared

    static func encodeBody<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decodeBody<T: Decodable>(_ record: Record, collection: String, writer: String, limit: Int) throws -> T {
        guard record.collection == collection, record.schema == 1, record.alive(),
              Set(record.fields.keys) == ["body"], record.stamps["body"]?.device == writer,
              let body = record["body"]?.string, body.utf8.count <= limit else { throw Failure.owner }
        return try JSONDecoder().decode(T.self, from: Data(body.utf8))
    }
}

/// A card or an address kept on a device that has no keychain of Yab's own
/// (the iPhone), in SyncWallet's record shape: a Mac in the account takes it
/// into its keychain as it takes another Mac's (docs/sync.md, "Passwords and
/// cards"), and a payment's answer names its id.
public enum AssistantWallet {
    /// "Visa", "Mastercard"…, as Wallet.brand(of:) says it.
    public static func brand(of digits: String) -> String {
        func starts(_ low: Int, _ high: Int, _ length: Int) -> Bool {
            guard digits.count >= length, let head = Int(digits.prefix(length)) else { return false }
            return (low...high).contains(head)
        }
        if digits.hasPrefix("4") { return "Visa" }
        if starts(51, 55, 2) || starts(2221, 2720, 4) { return "Mastercard" }
        if digits.hasPrefix("34") || digits.hasPrefix("37") { return "American Express" }
        if digits.hasPrefix("6011") || digits.hasPrefix("65") || starts(644, 649, 3) { return "Discover" }
        if starts(3528, 3589, 4) { return "JCB" }
        if digits.hasPrefix("62") { return "UnionPay" }
        if digits.hasPrefix("36") || starts(300, 305, 3) || digits.hasPrefix("38") { return "Diners Club" }
        if digits.hasPrefix("50") || starts(56, 69, 2) { return "Maestro" }
        return "Card"
    }

    public static func luhn(_ digits: String) -> Bool {
        guard (12...19).contains(digits.count), digits.allSatisfy(\.isNumber) else { return false }
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = Int(String(ch)) ?? 0
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// A `card` record's fields: the number and code sealed, what can be
    /// said of it in the clear.
    public static func card(id: String, number: String, csc: String, name: String, month: Int, year: Int,
                            seal: Seal, source: String = "Yab for iPhone") throws -> [String: Value] {
        let digits = number.filter(\.isNumber), code = csc.filter(\.isNumber)
        guard luhn(digits), (1...12).contains(month), year >= 2000, UUID(uuidString: id) != nil else {
            throw AssistantApprovalRecords.Failure.invalid
        }
        var secret = ["number": digits]
        if (3...4).contains(code.count) { secret["csc"] = code }
        let plain = try JSONSerialization.data(withJSONObject: secret, options: [.sortedKeys])
        let key = Record.Key(collection: SyncCollection.card, id: id)
        let facts: [String: Value] = [
            "last4": .string(String(digits.suffix(4))), "brand": .string(brand(of: digits)), "name": .string(name),
            "month": .number(Double(month)), "year": .number(Double(year)), "nickname": .string(""),
            "source": .string(source), "usedOn": .string(""), "issuer": .string(""), "level": .string(""),
            "billing": .string(""), "code": .bool((3...4).contains(code.count)),
        ]
        return ["secret": .string(try seal.hide(plain, in: key)), "facts": .object(facts)]
    }

    /// An `address` record's fields: the address sealed, as Wallet keeps a
    /// StreetAddress.
    public static func address(id: String, name: String, street: String, city: String, region: String = "",
                               postal: String, country: String = "", seal: Seal,
                               source: String = "Yab for iPhone") throws -> [String: Value] {
        guard UUID(uuidString: id) != nil, !street.trimmingCharacters(in: .whitespaces).isEmpty,
              !city.trimmingCharacters(in: .whitespaces).isEmpty else { throw AssistantApprovalRecords.Failure.invalid }
        let address: [String: String] = ["id": id, "name": name, "organization": "", "street": street, "city": city,
                                         "region": region, "postal": postal, "country": country, "phone": "", "email": "",
                                         "source": source]
        let plain = try JSONSerialization.data(withJSONObject: address, options: [.sortedKeys])
        let key = Record.Key(collection: SyncCollection.address, id: id)
        return ["secret": .string(try seal.hide(plain, in: key))]
    }
}
