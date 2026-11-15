import Foundation
import Testing
@testable import Fast

/// Values WebKit hands over that JSON has no form for. Before SafeJSON each
/// of these raised an Objective-C exception inside JSONSerialization, which
/// `try?` does not catch: the test process itself would have crashed.
struct SafeJSONTests {
    static let unwritable: [Any] = [
        ["at": Date()],
        ["n": Double.nan],
        ["n": NSNumber(value: Double.infinity)],
        [1, ["deep": [Double.nan]]],
        Date(),
        Double.nan,
    ]

    @Test func aValueJSONCannotHoldThrowsInsteadOfRaising() {
        for value in Self.unwritable {
            #expect(!SafeJSON.fits(value))
            #expect(throws: SafeJSON.NotJSON.self) { try SafeJSON.data(value) }
        }
    }

    @Test func plainValuesWriteAsBefore() throws {
        let value: [String: Any] = ["s": "text", "n": 1.5, "b": true, "z": NSNull(), "a": [1, 2]]
        let data = try SafeJSON.data(value, options: [.sortedKeys])
        #expect(String(decoding: data, as: UTF8.self) == #"{"a":[1,2],"b":true,"n":1.5,"s":"text","z":null}"#)
        #expect(try SafeJSON.data("fragment") == Data(#""fragment""#.utf8))
        #expect(try SafeJSON.data(3) == Data("3".utf8))
    }

    /// BoostScript.json takes a userscript's GM_setValue value straight from
    /// its message (Userscripts "set" with remove: true skips the store's guard).
    @Test func boostScriptJSONIsNullForUnwritableValues() {
        for value in Self.unwritable { #expect(BoostScript.json(value) == "null") }
        #expect(BoostScript.json(["k": "v"]) == #"{"k":"v"}"#)
    }

    /// A script moved from Tampermonkey keeps the values JSON can hold; an
    /// IndexedDB Date or a NaN among them is left out.
    @Test func movedScriptValuesKeepWhatJSONCanHold() {
        let kept = SafeJSON.keepable(["name": "x", "count": 2, "when": Date(), "ratio": Double.nan, "list": [1, 2]])
        #expect(Set(kept.keys) == ["name", "count", "list"])
        #expect((try? JSONSerialization.data(withJSONObject: kept)) != nil)
    }
}
