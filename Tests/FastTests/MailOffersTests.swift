import Foundation
import Testing
@testable import Fast
@testable import MailCore

// Offers from what you do (docs/mail.md, Offers from what you do): each from enough of
// the same, nothing about what a split has already, and a no kept with
// its reason.
struct MailOffersTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let me = MailPerson(name: "Me", address: "me@acme.io")
    static let hour: TimeInterval = 3600

    func mail(_ id: String, _ thread: String, from: MailPerson, to: [MailPerson] = [me], hours: Double, labels: Set<String>,
              list: Bool = false, subject: String = "Hi") -> MailMessage {
        MailMessage(id: id, thread: thread, from: from, to: to, subject: subject, snippet: "Words.",
                    date: Self.now.addingTimeInterval(-hours * Self.hour), labels: labels, listUnsubscribe: list, text: "Words.")
    }

    func store(_ messages: [MailMessage]) -> MailStore {
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        store.put(messages)
        return store
    }

    func offers(_ store: MailStore, splits: [MailList.Split] = [], declined: Set<String> = []) -> [MailOffer] {
        MailOffers.offers(account: "a", store: store, splits: splits, now: Self.now, declined: declined)
    }

    static let shop = MailPerson(name: "Shop", address: "deals@shop.example")

    /// Archived unopened, one a day: still unread, out of the inbox.
    func unopened(_ count: Int) -> [MailMessage] {
        (0..<count).map { mail("s\($0)", "shop\($0)", from: Self.shop, hours: Double(24 * $0 + 1), labels: ["UNREAD"]) }
    }

    // MARK: - hide

    @Test func mailYouNeverOpenIsOfferedHidden() throws {
        #expect(offers(store(unopened(7))).isEmpty)
        let store = store(unopened(8))
        let offer = try #require(offers(store).first)
        #expect(offer.kind == .hide && offer.key == "deals@shop.example" && offer.name == "Shop" && offer.count == 8)
        #expect(offer.home == "other")
        #expect(offer.words.before + offer.words.name + offer.words.after
                == "You archived 8 mails from Shop this month without opening one. Hide them here?")
        #expect(offer.button == "Hide Them")
        // One of them opened: you do read it.
        store.opened("shop3")
        #expect(offers(store).isEmpty)
    }

    @Test func nothingAboutWhatASplitHasAlready() {
        let split = MailList.Split(title: "Shop", q: "from:deals@shop.example")
        #expect(offers(store(unopened(9)), splits: [split]).isEmpty)
        let domain = MailList.Split(title: "Shop", q: "from:shop.example")
        #expect(offers(store(unopened(9)), splits: [domain]).isEmpty)
    }

    // MARK: - VIP

    @Test func whomYouAnswerWithinTheHourIsOfferedVIP() throws {
        let anna = MailPerson(name: "Anna Fold", address: "anna@fold.studio")
        var messages: [MailMessage] = []
        for n in 0..<10 {
            let at = Double(n * 30 + 5)
            messages.append(mail("a\(n)", "anna\(n)", from: anna, hours: at, labels: []))
            // Answered within half an hour, but the last, after three.
            messages.append(mail("r\(n)", "anna\(n)", from: Self.me, to: [anna], hours: at - (n == 9 ? 3 : 0.5), labels: ["SENT"]))
        }
        let store = store(messages)
        let offer = try #require(offers(store).first { $0.kind == .vip })
        #expect(offer.key == "anna@fold.studio" && offer.count == 9 && offer.detail == 10 && offer.home == "needs")
        #expect(offer.words.before + offer.words.name + offer.words.after
                == "You answer Anna Fold within an hour, 9 times out of 10. Put them in VIP?")
        // In VIP already, on or off: nothing to offer.
        let vip = MailList.Split(id: "vip", title: "VIP", q: "from:anna@fold.studio", on: false)
        #expect(!offers(store, splits: [vip]).contains { $0.kind == .vip })
    }

    // MARK: - by hand

    @Test func aLabelPutOnByHandIsOfferedASplit() throws {
        let kai = MailPerson(name: "Kai", address: "billing@ledgerly.example")
        let store = store((0..<10).map { mail("l\($0)", "inv\($0)", from: kai, hours: Double($0 + 1), labels: []) })
        store.logActs("label", threads: (0..<9).map { "inv\($0)" }, label: "Label_7", at: Self.now)
        #expect(!offers(store).contains { $0.kind == .label })
        store.logActs("label", threads: ["inv9"], label: "Label_7", at: Self.now)
        let offer = try #require(offers(store).first { $0.kind == .label })
        #expect(offer.count == 10 && offer.senders == ["billing@ledgerly.example"] && offer.button == "Make the Split")
    }

    @Test func aThreadArchivedAsItComesIsOfferedMuted() throws {
        let office = MailPerson(name: "Office", address: "office@acme.io")
        let store = MailStore(file: MailStore.memory)
        store.set("me", Self.me.address)
        for n in 0..<6 {
            let came = mail("o\(n)", "move", from: office, hours: Double(10 - n), labels: [], subject: "Re: Office move")
            store.put([came])
            store.logActs("archive", threads: ["move"], at: came.date.addingTimeInterval(30))
        }
        let offer = try #require(offers(store).first { $0.kind == .mute })
        #expect(offer.thread == "move" && offer.name == "Office move" && offer.count == 6)
    }

    @Test func aListYouNeverOpenIsOfferedUnsubscribe() throws {
        let daily = MailPerson(name: "Product Daily", address: "daily@news.example")
        let store = store((0..<5).map { mail("d\($0)", "daily\($0)", from: daily, hours: Double(24 * 8 * $0 + 2), labels: ["INBOX", "UNREAD"], list: true) })
        let offer = try #require(offers(store).first { $0.kind == .unsubscribe })
        // Its first this month came 24 days ago: as good as the month.
        #expect(offer.key == "daily@news.example" && offer.thread == "daily0" && offer.detail == 24)
        #expect(offer.words.before + offer.words.name + offer.words.after == "You haven\u{2019}t opened Product Daily in \(offer.detail) days. Unsubscribe?")
    }

    // MARK: - cold pitches (docs/mail.md, Offers from what you do)

    static let seller = MailPerson(name: "Dana Reed", address: "dana@acmeleads.example")

    func pitch(_ n: Int, answered: Bool) -> [MailMessage] {
        var out = [mail("p\(n)", "pitch\(n)", from: Self.seller, hours: Double(n * 24 + 5), labels: answered ? [] : ["INBOX", "UNREAD"])]
        if answered { out.append(mail("n\(n)", "pitch\(n)", from: Self.me, to: [Self.seller], hours: Double(n * 24 + 4), labels: ["SENT"])) }
        return out
    }

    @MainActor @Test func aStrangersPitchHasItsNoWrittenAhead() throws {
        let store = store(pitch(0, answered: false))
        store.keep(MailSensed(thread: "pitch0", message: "p0", needs: false, gist: "We run a launch agency.", due: nil, kind: .promotion))
        let ask = try #require(MailDrafts.pitching(store).first)
        #expect(ask.thread == "pitch0" && ask.text.contains("Dana Reed"))
        #expect(MailDrafts.declineSystem.contains("three ways to say no"))
        // Someone at that domain you wrote to: no stranger.
        store.put([mail("x", "earlier", from: Self.me, to: [MailPerson(name: "Lee", address: "lee@acmeleads.example")], hours: 900, labels: ["SENT"])])
        #expect(MailDrafts.pitching(store).isEmpty)
    }

    @Test func pitchesTurnedDownOfferTheNoAhead() throws {
        let store = store((0..<3).flatMap { pitch($0, answered: true) })
        for n in 0..<2 {
            store.keep(MailSensed(thread: "pitch\(n)", message: "p\(n)", needs: false, gist: "", due: nil, kind: .promotion))
        }
        #expect(!offers(store).contains { $0.kind == .decline })
        store.keep(MailSensed(thread: "pitch2", message: "p2", needs: false, gist: "", due: nil, kind: .promotion))
        let offer = try #require(offers(store).first { $0.kind == .decline })
        #expect(offer.words.before + offer.words.name + offer.words.after
                == "You turned down 3 pitches like these this month. Write the no ahead for cold pitches?")
        #expect(offer.button == "Write Ahead" && offer.home == "other")
    }

    // MARK: - no

    @Test func aNoIsKeptWithItsReason() throws {
        let defaults = try #require(UserDefaults(suiteName: "MailOffersTests.\(UUID().uuidString)"))
        let store = store(unopened(9))
        let offer = try #require(offers(store).first)
        MailOffers.decline(offer, why: .sender, defaults)
        #expect(offers(store, declined: MailOffers.declined(defaults)).isEmpty)
        // Fewer like this: twice the evidence first.
        let fewer: Set<String> = ["fewer:hide"]
        #expect(offers(store, declined: fewer).isEmpty)
        #expect(offers(self.store(unopened(16)), declined: fewer).first?.kind == .hide)
        // Never this kind.
        #expect(offers(self.store(unopened(16)), declined: ["never:hide"]).isEmpty)
        // Taken: not again.
        let other = try #require(UserDefaults(suiteName: "MailOffersTests.\(UUID().uuidString)"))
        MailOffers.took(offer, other)
        #expect(MailOffers.declined(other) == ["no:hide:deals@shop.example"])
    }

    // MARK: - mail app

    /// Yab as the Mac's mail app: over Needs you, the app links open in now
    /// by name; none once Yab is that app, or once answered.
    @Test func theMailAppOfferedOnce() throws {
        let offer = try #require(MailOffers.mailApp(current: "Mail", declined: []))
        #expect(offer.words.before + offer.words.name + offer.words.after
                == "Mail links in other apps open in Mail. Open them here, as a new mail?")
        #expect(offer.button == "Make Default" && offer.home == "needs")
        #expect(MailOffers.mailApp(current: nil, declined: []) == nil)
        let defaults = try #require(UserDefaults(suiteName: "MailOffersTests.\(UUID().uuidString)"))
        MailOffers.decline(offer, why: .never, defaults)
        #expect(MailOffers.mailApp(current: "Mail", declined: MailOffers.declined(defaults)) == nil)
        let other = try #require(UserDefaults(suiteName: "MailOffersTests.\(UUID().uuidString)"))
        MailOffers.took(offer, other)
        #expect(MailOffers.mailApp(current: "Mail", declined: MailOffers.declined(other)) == nil)
    }
}
