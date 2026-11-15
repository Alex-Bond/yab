import Foundation

// Offers from what you do (docs/mail.md, Offers from what you do): one card over the list
// it is about, and only when there is something to offer. Mail from one
// sender you keep archiving unopened: hide it here, in a split of its own
// only on this Mac, as ads are. Someone you answer within the hour: VIP. A
// label you put on by hand again and again: a split that gathers it. A list
// you never open: unsubscribe. A thread you archive the minute it comes:
// mute it.
//
// Read from the store as it stands (what you opened, what is out of the
// inbox unread) and from what you did by hand (`acts`, kept by MailOps).
// No to one says why, and that is kept: never this sender again, fewer
// like this (twice the evidence first), or never this kind.

struct MailOffer: Equatable, Identifiable, Sendable {
    /// `mailApp` first: Yab as the Mac's mail app (MailDefault), offered
    /// once mail is in, its name the app mail links open in now.
    enum Kind: String, Sendable, CaseIterable { case mailApp, vip, mute, hide, unsubscribe, label, decline }
    /// Why it was turned down.
    enum No: String, Sendable { case sender, fewer, never }

    let kind: Kind
    let account: String
    /// Whom or what it is about: an address, a thread, a label's id.
    let key: String
    /// Its name in the words: "Substack", "Anna", "Office move".
    let name: String
    let count: Int
    /// The thread to act on (unsubscribe, mute), and for a label, whom its
    /// mail came from.
    var thread = ""
    var senders: [String] = []
    /// "9 times out of 10", "40 days": what the words say besides the count.
    var detail = 0

    var id: String { kind.rawValue + ":" + key }
    /// The list whose head it stands over.
    var home: String { kind == .vip || kind == .mute || kind == .mailApp ? MailSplit.needs.rawValue : MailSplit.other.rawValue }

    /// The card's words, the name between: before, name, after.
    var words: (before: String, name: String, after: String) {
        switch kind {
        case .hide: return ("You archived \(count) mails from ", name, " this month without opening one. Hide them here?")
        case .vip: return ("You answer ", name, " within an hour, \(count) times out of \(detail). Put them in VIP?")
        case .label: return ("You labeled \(count) mails ", name, " by hand this month. Let a split do it?")
        case .unsubscribe: return ("You haven\u{2019}t opened ", name, " in \(detail) days. Unsubscribe?")
        case .mute: return ("You archived \(count) mails in ", name, " the minute they came. Mute the thread?")
        case .decline: return ("You turned down ", name, " like these this month. Write the no ahead for cold pitches?")
        case .mailApp: return ("Mail links in other apps open in ", name, ". Open them here, as a new mail?")
        }
    }

    var button: String {
        switch kind {
        case .hide: return "Hide Them"
        case .vip: return "Add to VIP"
        case .label: return "Make the Split"
        case .unsubscribe: return "Unsubscribe"
        case .mute: return "Mute"
        case .decline: return "Write Ahead"
        case .mailApp: return "Make Default"
        }
    }

    var icon: String {
        switch kind {
        case .hide: return "eye.slash"
        case .vip: return "star"
        case .label: return "tag"
        case .unsubscribe: return "rectangle.portrait.and.arrow.right"
        case .mute: return "speaker.slash"
        case .decline: return "hand.raised"
        case .mailApp: return "envelope"
        }
    }
}

enum MailOffers {
    /// Threads from one sender archived unopened this month, none opened.
    static let hideAfter = 8
    /// Of a person's last ten mails, answered within the hour.
    static let vipOf = (answered: 9, of: 10)
    /// Labels put on by hand this month.
    static let labelAfter = 10
    /// A list's mail, none opened, for this long.
    static let unsubscribeDays = 30
    /// Mails of one thread archived within two minutes of coming.
    static let muteAfter = 6
    static let month: TimeInterval = 30 * 86_400
    /// Cold pitches answered this month before the no is offered ahead.
    static let declineAfter = 3

    /// Cold pitches' rows say "No ready" and ⌘↩ in the list sends it
    /// (docs/mail.md, Offers from what you do): Write Ahead, or Settings › Mail.
    static let declinesKey = "mail.declines.list"
    static var declinesListed: Bool {
        get { Store.settings.bool(forKey: declinesKey) }
        set { Store.settings.set(newValue, forKey: declinesKey) }
    }

    /// What was turned down, kept as "sender:<key>", "fewer:<kind>",
    /// "never:<kind>" and "no:<offer id>".
    static let key = "mail.offers.no"

    static func declined(_ defaults: UserDefaults = Store.settings) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func decline(_ offer: MailOffer, why: MailOffer.No, _ defaults: UserDefaults = Store.settings) {
        var kept = declined(defaults)
        kept.insert("no:" + offer.id)
        switch why {
        case .sender: kept.insert("sender:" + offer.key)
        case .fewer: kept.insert("fewer:" + offer.kind.rawValue)
        case .never: kept.insert("never:" + offer.kind.rawValue)
        }
        defaults.set(kept.sorted(), forKey: key)
    }

    /// Taken: never offered again either.
    static func took(_ offer: MailOffer, _ defaults: UserDefaults = Store.settings) {
        var kept = declined(defaults)
        kept.insert("no:" + offer.id)
        defaults.set(kept.sorted(), forKey: key)
    }

    /// Yab as the Mac's mail app, while it isn't and this wasn't answered:
    /// `current`, the name of the app mail links open in now, nil when
    /// Yab is that app already.
    static func mailApp(current: String?, declined: Set<String> = MailOffers.declined()) -> MailOffer? {
        guard let current else { return nil }
        let offer = MailOffer(kind: .mailApp, account: "", key: "mail-app", name: current, count: 0)
        return declined.contains("no:" + offer.id) || declined.contains("never:" + offer.kind.rawValue) ? nil : offer
    }

    /// Whether an address is in one of the splits already (by itself or its
    /// domain).
    static func covered(_ address: String, by splits: [MailList.Split]) -> Bool {
        splits.contains { $0.on && names(address, in: $0.rules) }
    }

    /// Whether rules name an address, by itself or its domain.
    static func names(_ address: String, in rules: [MailRule]) -> Bool {
        let address = address.lowercased()
        return rules.contains { rule in
            guard rule.kind == "from" || rule.kind == "with" else { return false }
            let value = rule.value.lowercased()
            return value == address || (value.hasPrefix("@") ? address.hasSuffix(value) : address.hasSuffix("@" + value))
        }
    }

    /// A sender's name for the words: the name it goes by, else its domain.
    static func named(_ name: String, _ address: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        return address.split(separator: "@").last.map(String.init) ?? address
    }

    /// Everything one account offers now, VIP first, what was turned down
    /// left out.
    static func offers(account: String, store: MailStore, splits: [MailList.Split], now: Date,
                       declined: Set<String> = MailOffers.declined()) -> [MailOffer] {
        let fewer = { (kind: MailOffer.Kind) in declined.contains("fewer:" + kind.rawValue) ? 2 : 1 }
        var out: [MailOffer] = []
        let blocked = Set(store.blocked().map { $0.who.lowercased() })

        // Senders this month: hide what you never open, unsubscribe from a
        // list you don't.
        for sender in store.senders(since: now.addingTimeInterval(-month))
        where !blocked.contains(sender.address) && !covered(sender.address, by: splits) {
            let name = named(sender.name, sender.address)
            if sender.opened == 0, sender.outUnopened >= hideAfter * fewer(.hide), sender.outUnopened == sender.threads {
                out.append(MailOffer(kind: .hide, account: account, key: sender.address, name: name, count: sender.outUnopened))
            } else if sender.list, sender.opened == 0, sender.threads >= 4 * fewer(.unsubscribe), sender.outUnopened < sender.threads,
                      store.unsubscribed(from: sender.address) == nil {
                let days = Int(now.timeIntervalSince(sender.first) / 86_400)
                guard days >= unsubscribeDays * fewer(.unsubscribe) - 7, now.timeIntervalSince(sender.last) < 7 * 86_400 else { continue }
                var offer = MailOffer(kind: .unsubscribe, account: account, key: sender.address, name: name, count: sender.threads)
                offer.thread = sender.thread
                offer.detail = days
                out.append(offer)
            }
        }

        // Whom you answer within the hour, nearly always.
        let vip = splits.first { $0.id == "vip" }?.rules ?? []
        for (address, said) in store.answers(since: now.addingTimeInterval(-90 * 86_400), limit: vipOf.of) where said.waits.count >= vipOf.of {
            let quick = said.waits.filter { $0.map { $0 <= 3600 } ?? false }.count
            guard quick >= min(vipOf.of, vipOf.answered + fewer(.vip) - 1), !names(address, in: vip) else { continue }
            var offer = MailOffer(kind: .vip, account: account, key: address, name: named(said.name, address), count: quick)
            offer.detail = said.waits.count
            out.append(offer)
        }

        // What you did by hand this month: labels again and again, a thread
        // archived the minute each mail of it came.
        let acts = store.acts(since: now.addingTimeInterval(-month))
        let labelNames = Dictionary(store.labels().map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var labeled: [String: Set<String>] = [:]
        for act in acts where act.kind == MailOp.Kind.label.rawValue && !act.label.hasPrefix("name:") {
            labeled[act.label, default: []].insert(act.thread)
        }
        for (label, threads) in labeled where threads.count >= labelAfter * fewer(.label) {
            let senders = Array(Set(threads.compactMap { store.thread($0)?.people.first?.address.lowercased() })).sorted().prefix(8)
            guard !senders.isEmpty else { continue }
            var offer = MailOffer(kind: .label, account: account, key: label, name: labelNames[label] ?? label, count: threads.count)
            offer.senders = Array(senders)
            out.append(offer)
        }
        var quick: [String: Int] = [:]
        for act in acts where act.kind == MailOp.Kind.archive.rawValue && act.came.timeIntervalSince1970 > 0 && act.at.timeIntervalSince(act.came) < 120 {
            quick[act.thread, default: 0] += 1
        }
        let muted = Set(store.facts(now: now).filter(\.muted).map(\.id))
        for (thread, count) in quick where count >= muteAfter * fewer(.mute) && !muted.contains(thread) {
            guard let found = store.thread(thread) else { continue }
            var offer = MailOffer(kind: .mute, account: account, key: thread, name: MailCenter.bare(found.subject), count: count)
            offer.thread = thread
            out.append(offer)
        }

        // Pitches you keep turning down: the no ready in the list.
        if !declinesListed {
            let turned = store.pitchesAnswered(since: now.addingTimeInterval(-month))
            if turned >= declineAfter * fewer(.decline) {
                out.append(MailOffer(kind: .decline, account: account, key: "pitches", name: "\(turned) pitches", count: turned))
            }
        }

        let order = MailOffer.Kind.allCases
        let rank = { (offer: MailOffer) -> Int in order.firstIndex(of: offer.kind) ?? 0 }
        let left = out.filter { offer in
            !declined.contains("no:" + offer.id) && !declined.contains("never:" + offer.kind.rawValue) && !declined.contains("sender:" + offer.key)
        }
        return left.sorted { a, b in rank(a) != rank(b) ? rank(a) < rank(b) : a.count > b.count }
    }
}
