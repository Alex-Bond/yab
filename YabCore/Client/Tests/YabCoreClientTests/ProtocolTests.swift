import XCTest
@testable import YabCoreClient
final class ProtocolTests: XCTestCase {
    func testJSONRoundTripPreservesBooleanNullAndUnicode() throws {
        let value: JSONValue = .object(["bool": .bool(true), "null": .null,
            "text": .string("a\n\"日本語"), "array": .array([.number(42), .object([:])])])
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)), value)
    }
    func testRejectsNonJSONNumbers() {
        XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.number(.nan)))
        XCTAssertThrowsError(try JSONEncoder().encode(JSONValue.number(.infinity)))
    }
    func testRequestFramingDoesNotInjectLines() throws {
        let data = try JSONEncoder().encode(Request(id: "1", method: "script.evaluate", params: ["function": .string("a\nb")]))
        XCTAssertFalse(data.contains(10))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["v"] as? Int, 1)
    }
}
