import CoreGraphics
import Foundation
import XCTest
@testable import Fast

// A bench answer is always written (#381): a probe that came upon a view
// mid-layout, NaN or infinitely far, once took Yab down instead, the reply
// empty and the next call refused.

final class BenchAnswerTests: XCTestCase {
    func testWholeNumbersOfPlacesThatArentFinite() {
        XCTAssertEqual(Bench.whole(12.6), 13)
        XCTAssertEqual(Bench.whole(-4.4), -4)
        XCTAssertEqual(Bench.whole(.nan), 0)
        XCTAssertEqual(Bench.whole(.infinity), 0)
        XCTAssertEqual(Bench.whole(-.infinity), 0)
        XCTAssertEqual(Bench.whole(CGRect.null.minX), 0)
        XCTAssertEqual(Bench.whole(1e300), Int(1e15))
    }

    func testAnAnswerJSONCantHoldIsMadeWritable() throws {
        let answer: [String: Any] = [
            "words": "kept", "count": 3, "on": true, "none": NSNull(),
            "card": [CGRect.null.minX, 4.0, Double.nan],
            "spot": ["x": CGFloat.infinity, "y": CGFloat(2)],
            "rows": [["at": Float.nan, "id": "a"]],
            "when": Date(timeIntervalSince1970: 0),
        ]
        XCTAssertFalse(JSONSerialization.isValidJSONObject(answer))
        let writable = try XCTUnwrap(Bench.writable(answer) as? [String: Any])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(writable))
        let data = try JSONSerialization.data(withJSONObject: writable)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(back["words"] as? String, "kept")
        XCTAssertEqual(back["count"] as? Int, 3)
        XCTAssertEqual(back["on"] as? Bool, true)
        let card = try XCTUnwrap(back["card"] as? [Any])
        XCTAssertTrue(card[0] is NSNull)
        XCTAssertEqual(card[1] as? Double, 4)
        XCTAssertTrue(card[2] is NSNull)
        XCTAssertTrue((back["spot"] as? [String: Any])?["x"] is NSNull)
        XCTAssertEqual((back["spot"] as? [String: Any])?["y"] as? Double, 2)
        XCTAssertTrue(((back["rows"] as? [[String: Any]])?.first?["at"]) is NSNull)
        XCTAssertNotNil(back["when"] as? String)
    }

    func testAWritableAnswerIsLeftAsItIs() throws {
        let answer: [String: Any] = ["windows": [["frame": [0, 0, 800, 600], "title": "Yab"]], "scale": 2.0]
        XCTAssertTrue(JSONSerialization.isValidJSONObject(answer))
        let writable = try XCTUnwrap(Bench.writable(answer) as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: writable, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: answer, options: .sortedKeys))
    }
}
