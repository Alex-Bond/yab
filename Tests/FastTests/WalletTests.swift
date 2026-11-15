import Testing
import SwiftUI
import Foundation
@testable import Fast

// What a card number says about itself, and a card put together from the
// frames a page keeps its boxes in.
struct WalletTests {
    @Test func theCheckDigitIsRead() {
        #expect(Wallet.luhn("4242424242424242"))
        #expect(Wallet.luhn("5555555555554444"))
        #expect(!Wallet.luhn("4242424242424241"))
        #expect(!Wallet.luhn("42424242"))
        #expect(!Wallet.luhn("4242 4242 4242 4242"))
    }

    @Test func theNetworkComesFromTheFirstDigits() {
        #expect(Wallet.brand(of: "4242424242424242") == "Visa")
        #expect(Wallet.brand(of: "5555555555554444") == "Mastercard")
        #expect(Wallet.brand(of: "2223003122003222") == "Mastercard")
        #expect(Wallet.brand(of: "378282246310005") == "American Express")
        #expect(Wallet.brand(of: "6011111111111117") == "Discover")
    }

    @Test func aYearIsFourDigitsAndNoneStaysNone() {
        #expect(Wallet.fullYear(31) == 2031)
        #expect(Wallet.fullYear(2031) == 2031)
        #expect(Wallet.fullYear(0) == 0)
    }

    /// The page around the frames sends the name alone, with no date: it
    /// must not wipe out the date the date's frame said.
    @Test func aPartSaidElsewhereIsKept() {
        var card = SeenCard(["number": "5555555555554444", "month": 11, "year": 31])!
        card.take(SeenCard(["number": "", "name": "Jane Appleseed", "month": 0, "year": 0])!)
        #expect(card.number == "5555555555554444")
        #expect(card.month == 11 && card.year == 2031)
        #expect(card.name == "Jane Appleseed")
        #expect(card.keepable)
    }

    @Test func aStreetAddressIsTheSameHoweverSpelled() {
        var a = StreetAddress(id: "a")
        a.name = "Jane Appleseed"; a.street = "221 Mission St"; a.postal = "94105"; a.city = "SF"
        var b = StreetAddress(id: "b")
        b.name = "jane appleseed"; b.street = "221 Mission St.\nApt 4"; b.postal = "94105 "
        #expect(a.same(as: b))
        b.postal = "94103"
        #expect(!a.same(as: b))
    }

    private func place(_ street: String, city: String = "San Francisco", postal: String = "94158", country: String = "") -> StreetAddress {
        var a = StreetAddress(id: "a")
        a.street = street; a.city = city; a.postal = postal; a.country = country
        return a
    }

    /// The list under a field: the street with its number whole, the
    /// apartment apart, the building's name and the place under it.
    @Test func aListSaysTheStreetFirstAndTheApartmentApart() {
        let azure = place("Azure, 690 Long Bridge Street, Apt. 1210")
        #expect(azure.listStreet == "690 Long Bridge St")
        #expect(azure.listUnit == "Apt 1210")
        #expect(azure.listPlace == "Azure · San Francisco 94158")

        let dover = place("1111b South Governors Avenue, Building C, Suite 400", city: "Dover", postal: "19904-2210")
        #expect(dover.listStreet == "1111b S Governors Ave, Bldg C")
        #expect(dover.listUnit == "Suite 400")
        #expect(dover.listPlace == "Dover 19904")

        let lines = place("221 Mission St\n#4")
        #expect(lines.listStreet == "221 Mission St" && lines.listUnit == "#4")

        let berlin = place("Torstraße 109\n3. OG", city: "Berlin", postal: "10119", country: "DE")
        #expect(berlin.listStreet == "Torstraße 109")
        #expect(berlin.listPlace == "10119 Berlin")

        let paris = place("14 Place Vendôme", city: "Paris", postal: "75001", country: "France")
        #expect(paris.listStreet == "14 Place Vendôme")

        var work = place("2261 Market Street, Suite 4021", postal: "94114")
        work.organization = "Acme Labs"
        #expect(work.listPlace == "Acme Labs · San Francisco 94114")
    }

    /// In a name or an email box, an address's row says what goes in that
    /// box; in a street's, nothing of its own.
    @Test func aRowInANameOrEmailBoxSaysThat() {
        var home = place("690 Long Bridge St, Apt 1210")
        home.name = "Sam Rivera"
        home.email = "s@example.com"
        #expect(home.listOwn("name") == "Sam Rivera")
        #expect(home.listOwn("given") == "Sam" && home.listOwn("family") == "Rivera")
        #expect(home.listOwn("email") == "s@example.com")
        #expect(home.listOwn("line1") == nil && home.listOwn("") == nil)
        home.email = ""
        #expect(home.listOwn("email") == nil)
    }

    /// A city and a state written into the street go to their own boxes,
    /// and nothing else moves.
    @Test func aCityInTheStreetIsMovedDown() {
        let tidy = place("500 Brannan St, San Francisco, CA", city: "", postal: "94107").tidied()
        #expect(tidy.street == "500 Brannan St")
        #expect(tidy.city == "San Francisco" && tidy.region == "CA")

        let other = place("500 Brannan St, Oakland, CA", city: "San Francisco")
        #expect(other.tidied() == other)
        let unit = place("690 Long Bridge St, Apt 1210, CA")
        #expect(unit.tidied() == unit)
        let plain = place("1023 3rd St")
        #expect(plain.tidied() == plain)
    }

    @Test func aRowSaysWhenInShortWords() {
        let now = Date()
        #expect(FieldListRow<EmptyView>.ago(now.addingTimeInterval(-8), now: now) == "now")
        #expect(FieldListRow<EmptyView>.ago(now.addingTimeInterval(-21 * 86_400), now: now) == "3 wk")
        #expect(FieldListRow<EmptyView>.ago(now.addingTimeInterval(-40 * 86_400), now: now) == "1 mo")
    }
}
