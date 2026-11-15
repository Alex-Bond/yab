import Foundation
import XCTest
@testable import Fast

final class CrashFaultRegionTests: XCTestCase {
    private let home = "/Users/someone"
    private let head = #"{"app_name":"yab","bug_type":"309"}"#

    // Apple's containing-region arrow row, with neighboring rows omitted:
    // https://developer.apple.com/documentation/xcode/investigating-memory-access-crashes
    private let appleRegion = "--->  STACK GUARD            000000016c070000-000000016c074000 [   16K] ---/rwx SM=NUL  ...for thread 11"

    private func quoted(_ value: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), as: UTF8.self)
    }

    private func body(region: String? = nil,
                      exception: String = #"{"type":"EXC_BAD_ACCESS","rawCodes":[2,6107367984]}"#,
                      extra: String? = nil) throws -> String {
        var fields = [
            "\"exception\":\(exception)",
            #""faultingThread":0"#,
            #""threads":[{"id":1,"triggered":true,"frames":[{"imageIndex":0,"imageOffset":42}],"threadState":{"sp":{"value":555667788},"private":"register-private"}}]"#,
            "\"vmSummary\":\(try quoted("mapped \(home)/Documents/taxes-private.pdf"))",
            #""usedImages":[{"name":"yab"}]"#,
        ]
        if let region { fields.append("\"vmRegionInfo\":\(try quoted(region))") }
        if let extra { fields.append(extra) }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func prepared(_ body: String, file: StaticString = #filePath, line: UInt = #line) throws -> Crashes.Report {
        let report = head + "\n" + body
        guard case let .send(sent) = Crashes.prepared(report, home: home, bytes: report.utf8.count, age: 60) else {
            XCTFail("Expected a prepared report", file: file, line: line)
            throw NSError(domain: "CrashFaultRegionTests", code: 1)
        }
        return sent
    }

    private func payload(_ report: Crashes.Report) throws -> [String: Any] {
        let parts = report.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.first.map { String($0) }, head)
        let json = try XCTUnwrap(parts.count == 2 ? String(parts[1]).data(using: .utf8) : nil)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
    }

    private func assertUnknown(_ body: String, _ context: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let kept = try payload(prepared(body, file: file, line: line))
        XCTAssertNil(kept["faultInStackGuard"], context + " must remain unknown, not false", file: file, line: line)
    }

    private func assertPrivateFieldsStayLocal(_ report: Crashes.Report,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        let kept = try payload(report)
        XCTAssertNil(kept["vmRegionInfo"], file: file, line: line)
        XCTAssertNil(kept["vmSummary"], file: file, line: line)
        let thread = try XCTUnwrap((kept["threads"] as? [[String: Any]])?.first)
        XCTAssertNil(thread["threadState"], file: file, line: line)
        XCTAssertNotNil(thread["frames"], file: file, line: line)
        for secret in ["taxes-private.pdf", "register-private", "555667788", "guard-private.pdf", "STACK GUARD"] {
            XCTAssertFalse(report.text.contains(secret), secret, file: file, line: line)
        }
    }

    func testAppleContainingGuardProducesOnlyTheDerivedScalar() throws {
        let region = appleRegion + "\n mapped file \(home)/Documents/guard-private.pdf"
        let sent = try prepared(body(region: region))
        let kept = try payload(sent)
        XCTAssertNil(sent.parse)
        XCTAssertEqual(kept["faultInStackGuard"] as? Bool, true)
        XCTAssertEqual(Set(kept.keys), ["exception", "faultingThread", "threads", "usedImages", "faultInStackGuard"])
        try assertPrivateFieldsStayLocal(sent)
    }

    func testGuardRangeIsHalfOpen() throws {
        let region = "---> STACK GUARD 1000-2000 [ 4K] ---/rwx SM=NUL"
        for address in [4096, 8191] {
            let exception = #"{"type":"EXC_BAD_ACCESS","rawCodes":[2,\#(address)]}"#
            XCTAssertEqual(try payload(prepared(body(region: region, exception: exception)))["faultInStackGuard"] as? Bool,
                           true, "inside address \(address)")
        }
        for address in [4095, 8192, 8193] {
            let exception = #"{"type":"EXC_BAD_ACCESS","rawCodes":[2,\#(address)]}"#
            try assertUnknown(body(region: region, exception: exception), "outside address \(address)")
        }
    }

    func testExactUnsignedAddressesDoNotLoseBitsAboveDoublePrecision() throws {
        let region = "---> STACK GUARD fffffffffffffff0-ffffffffffffffff [ 15] ---/rwx SM=NUL"
        let exception = #"{"type":"EXC_BAD_ACCESS","rawCodes":[2,18446744073709551614]}"#
        XCTAssertEqual(try payload(prepared(body(region: region, exception: exception)))["faultInStackGuard"] as? Bool, true)
        try assertUnknown(body(region: region, exception: #"{"type":"EXC_BAD_ACCESS","rawCodes":[2,18446744073709551615]}"#),
                          "UInt64 maximum is the excluded upper endpoint")
    }

    func testSignalSpellingDoesNotReplaceMemoryExceptionEvidence() throws {
        for signal in ["SIGSEGV", "SIGBUS"] {
            let exception = #"{"type":"EXC_BAD_ACCESS","signal":"\#(signal)","rawCodes":[2,6107367984]}"#
            XCTAssertEqual(try payload(prepared(body(region: appleRegion, exception: exception)))["faultInStackGuard"] as? Bool, true)
        }
        for type in ["EXC_CRASH", "EXC_BREAKPOINT", "EXC_BAD_INSTRUCTION", "EXC_RESOURCE"] {
            let exception = #"{"type":"\#(type)","signal":"SIGSEGV","rawCodes":[2,6107367984]}"#
            try assertUnknown(body(region: appleRegion, exception: exception), type)
        }
    }

    func testMissingOrWrongExceptionShapeCannotBecomePositive() throws {
        let exceptions = [
            "null", "[]", #""EXC_BAD_ACCESS""#, "{}",
            #"{"rawCodes":[2,6107367984]}"#,
            #"{"type":"EXC_BAD_ACCESS","subtype":"KERN_PROTECTION_FAILURE at 0x16c070a30"}"#,
            #"{"type":"EXC_BAD_ACCESS","rawCodes":null}"#,
            #"{"type":"EXC_BAD_ACCESS","rawCodes":{"0":2,"1":6107367984}}"#,
        ]
        for exception in exceptions {
            try assertUnknown(body(region: appleRegion, exception: exception), exception)
        }
    }

    func testRawCodesRequireExactlyTwoUnsignedIntegerValues() throws {
        let codes = [
            "[]", "[2]", "[2,6107367984,0]",
            "[1,6107367984]", "[0,6107367984]", "[-2,6107367984]",
            "[true,6107367984]", "[false,6107367984]", "[2,true]", "[2,false]",
            #"["2",6107367984]"#, #"[2,"6107367984"]"#, "[2,null]",
            "[2,-1]", "[2,6107367984.25]", "[2.5,6107367984]",
            "[2,18446744073709551616]", "[18446744073709551616,6107367984]",
        ]
        for code in codes {
            let exception = #"{"type":"EXC_BAD_ACCESS","rawCodes":\#(code)}"#
            try assertUnknown(body(region: appleRegion, exception: exception), code)
        }
    }

    func testLossyFloatingAddressCannotMatchItsRoundedGuardRange() throws {
        let region = "---> STACK GUARD 20000000000000-20000000000010 [ 16] ---/rwx SM=NUL"
        for address in ["9007199254740993.1", "9.007199254740993e15", "1e100"] {
            let exception = #"{"type":"EXC_BAD_ACCESS","rawCodes":[2,\#(address)]}"#
            try assertUnknown(body(region: region, exception: exception), address)
        }
    }

    func testInvalidNumbersCannotBecomeSmallOrWrappedGuardAddresses() throws {
        let cases = [
            ("---> STACK GUARD 0-2", "[2,true]"),
            ("---> STACK GUARD 0-2", "[2,false]"),
            ("---> STACK GUARD 0-2", "[2,-0.5]"),
            ("---> STACK GUARD 0-2", "[2,18446744073709551616]"),
            ("---> STACK GUARD fffffffffffffff0-ffffffffffffffff", "[2,-2]"),
        ]
        for (region, codes) in cases {
            let exception = #"{"type":"EXC_BAD_ACCESS","rawCodes":\#(codes)}"#
            try assertUnknown(body(region: region, exception: exception), codes)
        }
    }

    func testMissingAndNeighboringGuardsRemainUnknown() throws {
        try assertUnknown(body(), "missing region")
        for value in ["null", "true", "0", "[]", "{}"] {
            try assertUnknown(body(extra: "\"vmRegionInfo\":\(value)"), "region with wrong type: \(value)")
        }
        for region in [
            "",
            "STACK GUARD 16c070000-16c074000 [ 16K] ---/rwx SM=NUL",
            """
            ---> GAP OF 0x1000 BYTES
                 STACK GUARD 16c070000-16c074000 [ 16K] ---/rwx SM=NUL
            """,
            """
            ---> Stack 16c070000-16c074000 [ 16K] rw-/rwx SM=COW
                 STACK GUARD 16c074000-16c078000 [ 16K] ---/rwx SM=NUL
            """,
        ] {
            try assertUnknown(body(region: region), region)
        }
    }

    func testMalformedGuardRangesRemainUnknown() throws {
        for region in [
            "---> STACK GUARD 16c070000-16c070000",
            "---> STACK GUARD 16c074000-16c070000",
            "---> STACK GUARD 16c070000-",
            "---> STACK GUARD -16c074000",
            "---> STACK GUARD 16c070000-16c07400g",
            "---> STACK GUARD 1000000016c070000-1000000016c074000",
            "---> STACK GUARD 16c070000-10000000000000000",
            "---> STACK GUARDIAN 16c070000-16c074000",
            "prefix ---> STACK GUARD 16c070000-16c074000",
        ] {
            try assertUnknown(body(region: region), region)
        }
    }

    func testDuplicateOrConflictingContainingArrowsRemainUnknown() throws {
        let guardRow = "---> STACK GUARD 16c070000-16c074000 [ 16K] ---/rwx SM=NUL"
        for region in [
            guardRow + "\n" + guardRow,
            guardRow + "\n---> STACK GUARD 1000-2000",
            guardRow + "\n---> Stack 16c074000-16c078000",
            guardRow + "\n---> GAP OF 0x1000 BYTES",
        ] {
            try assertUnknown(body(region: region), region)
        }
    }

    func testIncomingFlagCannotSupplyOrOverrideEvidence() throws {
        for flag in ["true", "false", "null", "1", #""true""#] {
            try assertUnknown(body(extra: "\"faultInStackGuard\":\(flag)"), "spoofed \(flag)")
        }
        let sent = try prepared(body(region: appleRegion, extra: #""faultInStackGuard":false"#))
        XCTAssertEqual(try payload(sent)["faultInStackGuard"] as? Bool, true)
    }

    func testMendedJSONUsesTheSameEvidenceAndPrivacyRules() throws {
        // A literal unescaped control character forces prepared's existing JSON repair path.
        let brokenNote = "\"ignored\":\"raw\ncontrol\""
        let sent = try prepared(body(region: appleRegion, extra: brokenNote))
        XCTAssertEqual(sent.parse, "mended")
        XCTAssertEqual(try payload(sent)["faultInStackGuard"] as? Bool, true)
        try assertPrivateFieldsStayLocal(sent)

        let spoofed = try prepared(body(extra: brokenNote + ",\"faultInStackGuard\":true"))
        XCTAssertEqual(spoofed.parse, "mended")
        XCTAssertNil(try payload(spoofed)["faultInStackGuard"])
        try assertPrivateFieldsStayLocal(spoofed)
    }

    func testIrreparableJSONScrubsTheMapRegistersAndSpoofedFlag() throws {
        let region = appleRegion + "\n mapped file \(home)/Documents/guard-private.pdf"
        let json = try body(region: region, extra: #""faultInStackGuard":true"#)
        let sent = try prepared("not a JSON object\n" + json)
        XCTAssertTrue(try XCTUnwrap(sent.parse).hasPrefix("raw"))
        for key in ["vmRegionInfo", "threadState", "faultInStackGuard"] {
            XCTAssertNotNil(sent.text.range(of: "\"\(key)\"\\s*:\\s*null", options: .regularExpression), key)
        }
        for secret in ["STACK GUARD", "guard-private.pdf", "taxes-private.pdf", "register-private", "555667788"] {
            XCTAssertFalse(sent.text.contains(secret), secret)
        }
        XCTAssertNil(sent.text.range(of: #""faultInStackGuard"\s*:\s*true"#, options: .regularExpression))
        XCTAssertTrue(sent.text.contains(#""frames""#), "useful stack frames remain")
    }
}
