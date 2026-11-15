import Foundation

// What the pay sheet says and where it is, apart from how it is drawn
// (PaySheet) and what it does to the page (PayFlow): one value, changed by
// the person's clicks and keys, by Touch ID's answer and by what the site
// said, so every state can be reached and checked without a sheet on screen.
//
// One surface, a tray: the card or the address row opens a list in
// the sheet's own place, a list's last row opens a form there, and the total
// and Touch ID step aside until you are back.

struct PaySheetModel: Equatable {
    enum Pane: Equatable {
        case main, cards, places, newPlace, newCard

        var isList: Bool { self == .cards || self == .places }
        var isForm: Bool { self == .newPlace || self == .newCard }
    }

    /// Ready: the Pay button, nothing listening. Armed: Pay was pressed (a
    /// click or ⌘↩) and Touch ID listens; only a finger pays. Checking: the
    /// Mac's password is being asked. Paying: the yes is given and the
    /// site's own button is being pressed. Paid and declined: what the site
    /// said.
    enum Phase: Equatable { case ready, armed, checking, paying, paid, declined }

    /// How the yes is given: a finger on the sensor, or, on a Mac without
    /// Touch ID or after too many fingers that didn't match, its password.
    enum Proof: Equatable { case touchID, password }

    /// A card as the sheet names it: never its number.
    struct Card: Equatable, Identifiable {
        var id: String
        var brand: String
        var last4: String
        var name: String

        /// "Visa •••• 6411", "Amex •••• 1005".
        var title: String { "\(PaySheetModel.short(brand)) •••• \(last4)" }
    }

    /// A kept address as the sheet names it.
    struct Place: Equatable, Identifiable {
        var id: String
        /// "14 Grand St, New York".
        var line: String
        /// Who or what it is: "Home", "Office", a name.
        var who: String
        var mark: String = "house"
    }

    var site: String
    /// What is bought, as the page says it, under the site's name.
    var item: String
    /// "$42.10", as the page has it.
    var amount: String
    /// When it comes, if the page says: "Arrives Thursday, Oct 23 · free".
    var delivery = ""
    var cards: [Card] = []
    var places: [Place] = []
    var card: String?
    var place: String?
    /// Picked here by the person, so put into the page before the press.
    var cardPicked = false
    var placePicked = false
    /// Whether the page has boxes for a card, or an address, for a pick
    /// here to go into. Without, the row only says what is there.
    var takesCard = true
    var takesPlace = true

    var pane: Pane = .main
    var phase: Phase = .ready
    var proof: Proof = .touchID
    /// The lit row of a list, the "Add…" row last.
    var focus = 0
    /// Fingers that didn't match in a row.
    var misses = 0
    /// Touch ID gave way to the password while armed (three misses, or
    /// the sensor locked): the button says Use Password.
    var fellBack = false
    /// Bumped for each shake of the Touch ID button.
    var shakes = 0
    /// What the site's confirmation called the order, when it did.
    var order = ""

    /// Three fingers that don't match and it asks for the password.
    static let fingers = 3

    // MARK: what shows

    var chosenCard: Card? { cards.first { $0.id == card } }
    var chosenPlace: Place? { places.first { $0.id == place } }

    /// Nothing can change once Touch ID said yes: no ×, no chevrons, Esc
    /// doesn't cancel.
    var locked: Bool { phase == .checking || phase == .paying || phase == .paid }
    var cancellable: Bool { pane == .main && !locked }
    var showsTotal: Bool { pane == .main }
    var totalWord: String { phase == .paid ? "Paid" : "Total" }
    var cardOpens: Bool { !locked && takesCard }
    var placeOpens: Bool { !locked && takesPlace }
    /// Touch ID listens only once Pay was pressed, and only while the
    /// sheet shows what is paid for.
    var listening: Bool { pane == .main && proof == .touchID && phase == .armed }
    /// Pay can be pressed: a click or ⌘↩ arms the check.
    var armable: Bool { pane == .main && (phase == .ready || phase == .declined) }

    /// What the one button in the foot shows. It keeps its place and its
    /// width through all of them (the widest face's, PaySheet).
    enum Face: Equatable, CaseIterable {
        /// "Pay $42.10" with ⌘↩: arms the check, pays nothing.
        case pay
        /// Armed: where the finger goes, its mark breathing.
        case touch
        /// Armed, Touch ID given up: opens the password's dialog.
        case password
        case checking, paying, paid
    }

    var face: Face {
        switch phase {
        case .ready, .declined: return .pay
        case .armed: return proof == .touchID ? .touch : .password
        case .checking: return .checking
        case .paying: return .paying
        case .paid: return .paid
        }
    }

    /// The button's words for a face.
    func words(_ face: Face) -> String {
        switch face {
        case .pay: return amount.isEmpty ? "Pay" : "Pay \(amount)"
        case .touch: return "Touch ID"
        case .password: return "Use Password"
        case .checking: return "Checking"
        case .paying: return "Paying"
        case .paid: return "Paid"
        }
    }

    /// The line over the buttons, nil while the button says it all.
    var line: String? {
        let paying = amount.isEmpty ? "pay" : "pay \(amount)"
        switch phase {
        case .ready: return nil
        case .armed:
            if proof == .password { return "Use your Mac's password to \(paying) on \(site)" }
            return misses > 0 ? "Not recognized. Try again, or press Cancel." : "Touch ID to \(paying) on \(site)"
        case .checking: return "Waiting for your Mac's password"
        case .paying: return "Paying on \(site) · this can take a few seconds"
        case .paid: return order.isEmpty ? "Paid on \(site)" : "Order \(order)"
        case .declined: return "Payment not completed. Try again, or pick another card."
        }
    }

    /// The line in red: a finger not known, or the site said no.
    var lineBad: Bool { phase == .declined || (phase == .armed && proof == .touchID && misses > 0) }

    // MARK: lists

    /// The rows of the open list, its "Add…" row not counted.
    var rows: Int { pane == .cards ? cards.count : pane == .places ? places.count : 0 }

    mutating func open(_ list: Pane) {
        guard list.isList, !locked else { return }
        if list == .cards, !cardOpens { return }
        if list == .places, !placeOpens { return }
        // A step away from what the finger was asked for: Pay is pressed again.
        if phase == .armed { phase = .ready; misses = 0; fellBack = false }
        pane = list
        let current = list == .cards ? cards.firstIndex { $0.id == card } : places.firstIndex { $0.id == place }
        focus = current ?? 0
    }

    /// Back one step: a form to its list, a list to the sheet.
    mutating func back() {
        switch pane {
        case .newCard: pane = .cards; focus = cards.count
        case .newPlace: pane = .places; focus = places.count
        case .cards, .places: pane = .main
        case .main: break
        }
    }

    /// A row of the open list: the card or the address, or "Add…".
    mutating func pick(_ index: Int) {
        switch pane {
        case .cards:
            guard index < cards.count else { pane = .newCard; return }
            if cards[index].id != card { cardPicked = true }
            card = cards[index].id
            // Another card is another try: the red row goes.
            if phase == .declined { phase = .ready }
            pane = .main
        case .places:
            guard index < places.count else { pane = .newPlace; return }
            if places[index].id != place { placePicked = true }
            place = places[index].id
            pane = .main
        default:
            break
        }
    }

    /// A card or an address picked on another device (docs/approvals.md,
    /// "Details"): the list opened and its row picked, as a click there
    /// does. False when the list can't open or doesn't have it.
    @discardableResult
    mutating func choose(card id: String) -> Bool {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return false }
        open(.cards)
        guard pane == .cards else { return false }
        pick(index)
        return card == id
    }

    @discardableResult
    mutating func choose(place id: String) -> Bool {
        guard let index = places.firstIndex(where: { $0.id == id }) else { return false }
        open(.places)
        guard pane == .places else { return false }
        pick(index)
        return place == id
    }

    /// Kept from the form and picked at once.
    mutating func added(_ new: Card) {
        cards.removeAll { $0.id == new.id }
        cards.insert(new, at: 0)
        card = new.id
        cardPicked = true
        if phase == .declined { phase = .ready }
        pane = .main
    }

    mutating func added(_ new: Place) {
        places.removeAll { $0.id == new.id }
        places.insert(new, at: 0)
        place = new.id
        placePicked = true
        pane = .main
    }

    // MARK: keys

    enum Key: Equatable { case up, down, enter, escape, confirm }

    /// What a key asks of the sheet's owner, beyond the model's own change.
    enum Effect: Equatable {
        /// Kept by the sheet: nothing for the page.
        case none
        /// Not for the sheet: the key goes on where it was going.
        case ignored
        /// No, nothing is paid: the sheet goes.
        case cancel
        /// Pay pressed (⌘↩): Touch ID listens, or the password is asked.
        case arm
        /// ↩ on the Pay button: it takes ⌘↩, said in the corner.
        case needsKeys
        /// ⌘↩ or ↩ once armed: paying takes a finger, said in the corner.
        case needsFinger
        /// The form's Save.
        case save
    }

    mutating func key(_ key: Key) -> Effect {
        switch pane {
        case .main:
            switch key {
            case .escape: return cancellable ? .cancel : locked ? .none : .ignored
            case .confirm:
                if locked { return .none }
                if armable { return .arm }
                return phase == .armed && proof == .password ? .arm : .needsFinger
            case .enter:
                if locked { return .none }
                return armable ? .needsKeys : .needsFinger
            case .up, .down: return .ignored
            }
        case .cards, .places:
            let count = rows + 1
            switch key {
            case .down: focus = (focus + 1) % count
            case .up: focus = (focus + count - 1) % count
            case .enter: pick(focus)
            case .escape: back()
            case .confirm: return .ignored
            }
            return .none
        case .newCard, .newPlace:
            switch key {
            case .escape: back(); return .none
            case .enter: return .save
            default: return .ignored
            }
        }
    }

    // MARK: the yes and what the site said

    /// Touch ID's or the password's answer.
    enum Answer: Equatable {
        case yes
        /// A finger that didn't match: the disc shakes.
        case miss
        /// Gone without an answer: dismissed, or asked again.
        case quiet
        /// The Mac can't ask any more this way: its password then.
        case locked
    }

    /// Pay pressed: Touch ID listens from now. On a Mac that asks for its
    /// password the flow opens its dialog instead (`asking`).
    mutating func arm() {
        guard armable, proof == .touchID else { return }
        misses = 0
        phase = .armed
    }

    /// True when the yes is given and the press can go. Only an armed
    /// check (or the password's dialog) hears a finger; a yes from another
    /// device comes in whatever the sheet shows.
    @discardableResult
    mutating func answered(_ answer: Answer) -> Bool {
        guard phase == .armed || phase == .checking || (answer == .yes && (phase == .ready || phase == .declined)) else { return false }
        let back: Phase = fellBack ? .armed : .ready
        switch answer {
        case .yes:
            misses = 0
            phase = .paying
            return true
        case .miss:
            misses += 1
            shakes += 1
            if misses >= Self.fingers { proof = .password; misses = 0; fellBack = true }
            if phase == .checking { phase = back }
        case .quiet:
            if phase == .checking { phase = back }
        case .locked:
            proof = .password
            misses = 0
            if phase == .armed { fellBack = true }
            if phase == .checking { phase = fellBack ? .armed : .ready }
        }
        return false
    }

    /// The password's own dialog is up.
    mutating func asking() {
        guard pane == .main, phase == .ready || phase == .declined || phase == .armed else { return }
        phase = .checking
    }

    mutating func paid(order: String = "") {
        guard phase == .paying else { return }
        self.order = order
        phase = .paid
    }

    mutating func declined() {
        guard phase == .paying else { return }
        phase = .declined
        shakes += 1
    }

    /// The agent asked again, with what the page says now: the same sheet
    /// takes it, the total rolling to the new amount.
    mutating func asked(amount: String, item: String) {
        if !amount.isEmpty { self.amount = amount }
        if !item.isEmpty { self.item = item }
        // A new question is a new try: the press before it wasn't made.
        phase = .ready
        misses = 0
        fellBack = false
        pane = .main
    }

    // MARK: words

    /// A card's brand as a sheet says it, short: Amex, not American Express.
    static func short(_ brand: String) -> String {
        switch brand {
        case "American Express": return "Amex"
        case "Diners Club": return "Diners"
        default: return brand
        }
    }

    // MARK: the forms

    /// A new address may be kept once it says where: a street and a city
    /// or a ZIP.
    static func placeFilled(street: String, city: String, zip: String) -> Bool {
        let words = { (s: String) in !s.trimmingCharacters(in: .whitespaces).isEmpty }
        return words(street) && (words(city) || words(zip))
    }

    /// A new card may be kept once its number is one (Luhn) and it says
    /// when it runs out, a month that hasn't passed.
    static func cardFilled(number: String, expires: String, now: Date = Date()) -> Bool {
        let digits = number.filter(\.isNumber)
        guard (12...19).contains(digits.count), Wallet.luhn(digits), let (month, year) = expiry(expires) else { return false }
        let today = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: now)
        return (year, month) >= (today.year ?? 0, today.month ?? 0)
    }

    /// "08 / 29", "8/29", "0829", "08/2029": the month and the full year.
    static func expiry(_ text: String) -> (month: Int, year: Int)? {
        let parts = text.split { !$0.isNumber }.map(String.init)
        let month: Int?, year: Int?
        if parts.count >= 2 {
            month = Int(parts[0]); year = Int(parts[1])
        } else if let one = parts.first, one.count == 4 || one.count == 6 {
            month = Int(one.prefix(2)); year = Int(one.dropFirst(2))
        } else {
            return nil
        }
        guard let month, let year, (1...12).contains(month) else { return nil }
        let full = year < 100 ? Wallet.fullYear(year) : year
        guard (2000...2099).contains(full) else { return nil }
        return (month, full)
    }

    /// The number as it is typed, in fours (Amex in 4 6 5).
    static func spaced(_ number: String) -> String {
        let digits = String(number.filter(\.isNumber).prefix(19))
        let groups = Wallet.brand(of: digits) == "American Express" ? [4, 6, 5] : [4, 4, 4, 4, 3]
        var out: [String] = [], rest = Substring(digits)
        for size in groups where !rest.isEmpty {
            out.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
        }
        return out.joined(separator: " ")
    }
}

extension PaySheetModel.Card {
    init(_ card: SavedCard) {
        self.init(id: card.id, brand: card.brand, last4: card.last4, name: card.nickname.isEmpty ? card.name : card.nickname)
    }
}

extension PaySheetModel.Place {
    init(_ address: StreetAddress) {
        let line = [address.listStreet.isEmpty ? address.line1 : address.listStreet, address.city].filter { !$0.isEmpty }.joined(separator: ", ")
        let kind = address.source ?? ""
        let who = kind.hasSuffix(", work") ? "Office" : kind.hasSuffix("home") ? "Home" : address.name
        self.init(id: address.id, line: line.isEmpty ? address.title : line, who: who, mark: address.mark)
    }
}
