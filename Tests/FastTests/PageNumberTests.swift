import Testing
import Foundation
@testable import Fast

// Numbers a page sends are anything at all: a card's month and year, a form
// box's index and length. Crash #103 was Int(1e300) on a card's year.
struct PageNumberTests {
    static let odd: [Any] = [1e300, -1e300, Double.infinity, -Double.infinity, Double.nan, 3.5, -0.5,
                             Double.greatestFiniteMagnitude, Double(Int.max)]

    @Test func oddNumbersAreNotWhole() {
        for value in Self.odd {
            #expect(PageNumber.int(value) == nil, "\(value)")
            #expect(PageNumber.int(NSNumber(value: value as! Double)) == nil, "\(value)")
        }
        #expect(PageNumber.int(true) == nil)
        #expect(PageNumber.int("12") == nil)
        #expect(PageNumber.int(nil) == nil)
    }

    @Test func wholeNumbersAreTaken() {
        #expect(PageNumber.int(7) == 7)
        #expect(PageNumber.int(7.0) == 7)
        #expect(PageNumber.int(NSNumber(value: 2031.0)) == 2031)
        #expect(PageNumber.int(-3) == -3)
        #expect(PageNumber.int(-3.0, in: 0...9) == nil)
        #expect(PageNumber.int(12, in: 1...12) == 12)
        #expect(PageNumber.int(13, in: 1...12) == nil)
    }

    @Test func aCardWithOddDatesHasNoDate() {
        #expect(SeenCard(["month": 13, "year": 31])?.month == 0)
        let ints: [Any] = [-1, -2031, 0, 10_000, Int.max, Int.min]
        for value in Self.odd + ints {
            let card = SeenCard(["number": "4242424242424242", "month": value, "year": value])
            #expect(card?.month == 0, "\(value)")
            #expect(card?.year == 0, "\(value)")
            #expect(card?.keepable == false)
        }
    }

    @Test func aCardsDateIsStillRead() {
        let card = SeenCard(["number": "4242 4242 4242 4242", "month": 4.0, "year": 31.0])
        #expect(card?.month == 4)
        #expect(card?.year == 2031)
        #expect(SeenCard(["month": 12, "year": 2034])?.year == 2034)
        #expect(SeenCard(["month": 1, "year": 9999])?.year == 9999)
    }

    @Test func aFormBoxWithOddNumbersIsSafe() {
        for value in Self.odd {
            #expect(FormField(["i": value]) == nil, "\(value)")
            #expect(FormField(["i": 2, "maxLength": value])?.maxLength == 0, "\(value)")
        }
        #expect(FormField(["i": 2.0, "maxLength": 5.0])?.index == 2)
        #expect(FormField(["i": 2, "maxLength": 5])?.maxLength == 5)
        #expect(FormField(["i": 2, "maxLength": -1])?.maxLength == -1)
    }

    @Test func aRectWithOddSidesIsNone() {
        for value in [Double.infinity, -Double.infinity, Double.nan] {
            #expect(PageNumber.rect(["x": value, "y": 0, "w": 10, "h": 10]) == nil)
            #expect(PageNumber.rect(["x": 0, "y": 0, "w": 10, "h": value]) == nil)
        }
        #expect(PageNumber.rect(["x": 1, "y": 2, "w": 3]) == nil)
        #expect(PageNumber.rect(["x": 1.5, "y": 2, "w": 3, "h": 4]) == CGRect(x: 1.5, y: 2, width: 3, height: 4))
    }
}
