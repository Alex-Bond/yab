import Foundation
import Testing
@testable import Fast

/// The pay sheet's states (PaySheetModel): lists and forms in the sheet's
/// own place, the keys, Touch ID's answers, and what the site said.
@MainActor
struct PaySheetTests {
    private func sheet() -> PaySheetModel {
        var model = PaySheetModel(site: "amazon.com", item: "Oxford Shirt · Navy · M", amount: "$42.10")
        model.cards = [.init(id: "v", brand: "Visa", last4: "6411", name: "Sam Rivera"),
                       .init(id: "m", brand: "Mastercard", last4: "2210", name: "Sam Rivera"),
                       .init(id: "a", brand: "American Express", last4: "1005", name: "Acme Labs")]
        model.places = [.init(id: "h", line: "14 Grand St, New York", who: "Home"),
                        .init(id: "o", line: "85 Broad St, New York", who: "Office", mark: "building.2")]
        model.card = "v"
        model.place = "h"
        return model
    }

    @Test func readyIsAPayButtonAndNothingListens() {
        let model = sheet()
        #expect(model.showsTotal)
        #expect(!model.listening, "Touch ID waits for Pay to be pressed")
        #expect(model.cancellable)
        #expect(model.totalWord == "Total")
        #expect(model.face == .pay)
        #expect(model.words(.pay) == "Pay $42.10")
        #expect(model.line == nil)
        #expect(model.chosenCard?.title == "Visa •••• 6411")
    }

    @Test func pressingPayArmsTouchID() {
        var model = sheet()
        let effect = model.key(.confirm)
        #expect(effect == .arm, "⌘↩ presses Pay")
        model.arm()
        #expect(model.phase == .armed)
        #expect(model.listening)
        #expect(model.face == .touch)
        #expect(model.words(.touch) == "Touch ID")
        #expect(model.line == "Touch ID to pay $42.10 on amazon.com")
        #expect(!model.lineBad)
        #expect(model.cancellable, "Cancel stands beside Touch ID")
        let again = model.key(.confirm)
        #expect(again == .needsFinger, "once armed ⌘↩ pays nothing")
        #expect(model.phase == .armed)
        let escape = model.key(.escape)
        #expect(escape == .cancel)
    }

    @Test func aListDisarms() {
        var model = sheet()
        model.arm()
        model.open(.cards)
        #expect(!model.listening)
        model.back()
        #expect(model.phase == .ready, "Pay is pressed again for what the sheet shows now")
    }

    @Test func listTakesTheSheetAndTotalStepsAside() {
        var model = sheet()
        model.open(.cards)
        #expect(model.pane == .cards)
        #expect(!model.showsTotal)
        #expect(!model.listening, "a finger while picking pays nothing")
        #expect(model.focus == 0, "the current card is lit")
        model.pick(1)
        #expect(model.pane == .main)
        #expect(model.card == "m")
        #expect(model.cardPicked)
        #expect(model.showsTotal)
    }

    @Test func keysInAList() {
        var model = sheet()
        model.open(.places)
        let effect1 = model.key(.down)
        #expect(effect1 == .none)
        #expect(model.focus == 1)
        let effect2 = model.key(.down)
        #expect(effect2 == .none)
        #expect(model.focus == 2, "the Add Address… row")
        let effect3 = model.key(.down)
        #expect(effect3 == .none)
        #expect(model.focus == 0, "round again")
        let effect4 = model.key(.up)
        #expect(effect4 == .none)
        #expect(model.focus == 2)
        let effect5 = model.key(.enter)
        #expect(effect5 == .none)
        #expect(model.pane == .newPlace, "↩ on Add Address… opens the form")
        let effect6 = model.key(.escape)
        #expect(effect6 == .none)
        #expect(model.pane == .places, "Esc in a form goes back to its list")
        #expect(model.focus == 2)
        let effect7 = model.key(.escape)
        #expect(effect7 == .none)
        #expect(model.pane == .main, "Esc in a list goes back")
        let effect8 = model.key(.escape)
        #expect(effect8 == .cancel, "Esc on the sheet cancels")
    }

    @Test func keysNeverPay() {
        var model = sheet()
        let effect9 = model.key(.confirm)
        #expect(effect9 == .arm)
        let effect10 = model.key(.enter)
        #expect(effect10 == .needsKeys, "a bare ↩ says Pay takes ⌘↩")
        #expect(model.phase == .ready)
        let early = model.answered(.miss)
        #expect(!early && model.misses == 0, "no finger is heard before Pay is pressed")
        model.arm()
        let effect11 = model.key(.enter)
        #expect(effect11 == .needsFinger)
        #expect(model.phase == .armed)
    }

    @Test func pickingTheSameCardIsNoPick() {
        var model = sheet()
        model.open(.cards)
        model.pick(0)
        #expect(!model.cardPicked, "nothing to put into the page")
    }

    @Test func addingPicksWhatWasAdded() {
        var model = sheet()
        model.open(.places)
        model.pick(model.places.count)
        #expect(model.pane == .newPlace)
        model.added(PaySheetModel.Place(id: "n", line: "500 Kent Ave, Brooklyn", who: "Sam Rivera"))
        #expect(model.pane == .main)
        #expect(model.place == "n")
        #expect(model.placePicked)
        #expect(model.places.first?.id == "n")
    }

    @Test func touchIDYesLocksTheSheet() {
        var model = sheet()
        model.arm()
        let yes = model.answered(.yes)
        #expect(yes)
        #expect(model.phase == .paying)
        #expect(model.locked)
        #expect(!model.cancellable)
        #expect(!model.cardOpens && !model.placeOpens, "no chevrons while paying")
        let effect11 = model.key(.escape)
        #expect(effect11 == .none, "Esc doesn't cancel while the site is pressed")
        model.open(.cards)
        #expect(model.pane == .main)
        #expect(model.face == .paying)
        #expect(model.line == "Paying on amazon.com · this can take a few seconds")
    }

    @Test func threeMissesAskForThePassword() {
        var model = sheet()
        model.arm()
        model.answered(.miss)
        #expect(model.line == "Not recognized. Try again, or press Cancel.")
        #expect(model.lineBad)
        #expect(model.shakes == 1)
        #expect(model.phase == .armed, "still armed: another finger")
        model.answered(.miss)
        model.answered(.miss)
        #expect(model.shakes == 3)
        #expect(model.proof == .password)
        #expect(model.face == .password)
        #expect(model.words(.password) == "Use Password")
        #expect(model.line == "Use your Mac's password to pay $42.10 on amazon.com")
        #expect(!model.lineBad)
        #expect(!model.listening)
        let effect = model.key(.confirm)
        #expect(effect == .arm, "⌘↩ on Use Password opens the dialog, which still asks")
        model.asking()
        #expect(model.phase == .checking)
        #expect(model.face == .checking)
        model.answered(.quiet)
        #expect(model.phase == .armed, "the dialog dismissed: Use Password again")
    }

    @Test func noTouchIDOnTheMac() {
        var model = sheet()
        model.proof = .password
        model.arm()
        #expect(model.phase == .ready, "no finger to arm for: the flow asks the password")
        model.asking()
        #expect(model.phase == .checking)
        model.answered(.quiet)
        #expect(model.phase == .ready, "dismissed: Pay again")
        model.asking()
        let yes = model.answered(.yes)
        #expect(yes)
    }

    @Test func aYesFromAnotherDeviceNeedsNoPress() {
        var model = sheet()
        let yes = model.answered(.yes)
        #expect(yes)
        #expect(model.phase == .paying)
    }

    @Test func paidRewordsTotalAndKeepsAmount() {
        var model = sheet()
        model.arm()
        model.answered(.yes)
        model.paid(order: "112-4")
        #expect(model.phase == .paid)
        #expect(model.face == .paid)
        #expect(model.totalWord == "Paid")
        #expect(model.amount == "$42.10")
        #expect(model.line == "Order 112-4")
        let effect12 = model.key(.escape)
        #expect(effect12 == .none)
    }

    @Test func declinedLetsAnotherCardTry() {
        var model = sheet()
        model.answered(.yes)
        model.declined()
        #expect(model.phase == .declined)
        #expect(model.shakes == 1)
        #expect(model.cancellable, "Esc leaves; nothing was charged")
        #expect(!model.listening)
        #expect(model.face == .pay, "Pay again to try again")
        #expect(model.lineBad)
        let retry = model.key(.confirm)
        #expect(retry == .arm)
        model.open(.cards)
        #expect(model.pane == .cards)
        model.pick(2)
        #expect(model.phase == .ready, "another card is another try")
        #expect(model.card == "a")
        model.arm()
        let again = model.answered(.yes)
        #expect(again, "and it can be paid again")
    }

    @Test func askedAgainRollsTheTotal() {
        var model = sheet()
        model.open(.places)
        model.asked(amount: "$47.09", item: "")
        #expect(model.amount == "$47.09")
        #expect(model.pane == .main)
        #expect(model.item == "Oxford Shirt · Navy · M")
    }

    @Test func noPicksWhereThePageTakesNone() {
        var model = sheet()
        model.takesCard = false
        model.open(.cards)
        #expect(model.pane == .main)
    }

    @Test func formsSaveWhenFilled() {
        #expect(!PaySheetModel.placeFilled(street: "", city: "Brooklyn", zip: ""))
        #expect(!PaySheetModel.placeFilled(street: "500 Kent Ave", city: " ", zip: ""))
        #expect(PaySheetModel.placeFilled(street: "500 Kent Ave", city: "Brooklyn", zip: ""))
        #expect(PaySheetModel.placeFilled(street: "500 Kent Ave", city: "", zip: "11249"))

        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 19))!
        #expect(PaySheetModel.cardFilled(number: "4242 4242 4242 4242", expires: "08 / 29", now: now))
        #expect(!PaySheetModel.cardFilled(number: "4242 4242 4242 4241", expires: "08 / 29", now: now), "not a card number")
        #expect(!PaySheetModel.cardFilled(number: "4242 4242 4242 4242", expires: "09 / 26", now: now), "run out")
        #expect(PaySheetModel.cardFilled(number: "4242424242424242", expires: "1026", now: now), "its last month still pays")
        #expect(!PaySheetModel.cardFilled(number: "4242 4242 4242 4242", expires: "13/29", now: now))
    }

    @Test func expiryReadsTheWaysItIsTyped() {
        #expect(PaySheetModel.expiry("08 / 29").map { [$0.month, $0.year] } == [8, 2029])
        #expect(PaySheetModel.expiry("8/29").map { [$0.month, $0.year] } == [8, 2029])
        #expect(PaySheetModel.expiry("0829").map { [$0.month, $0.year] } == [8, 2029])
        #expect(PaySheetModel.expiry("08/2031").map { [$0.month, $0.year] } == [8, 2031])
        #expect(PaySheetModel.expiry("8") == nil)
    }

    @Test func numbersAreSpacedAsCardsPrintThem() {
        #expect(PaySheetModel.spaced("4242424242424242") == "4242 4242 4242 4242")
        #expect(PaySheetModel.spaced("378282246310005") == "3782 822463 10005")
    }

    @Test func shortNames() {
        #expect(PaySheetModel.short("American Express") == "Amex")
        #expect(PaySheetModel.Card(id: "x", brand: "Mastercard", last4: "2210", name: "").title == "Mastercard •••• 2210")
    }
}
