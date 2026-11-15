import XCTest
@testable import Fast

@MainActor
final class StampServerDateTests: XCTestCase {
    private func settings(_ check: (UserDefaults) throws -> Void) rethrows {
        let name = "dev.serafim.fast.test.server-stamp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try check(defaults)
    }

    // A normal cached date reaches the weak-linked Date >= operator in 0.46.1.
    // On the reporter's macOS 27.2 it calls address zero during startup.
    func testPositiveStoredServerDateOnLaunch() {
        settings { defaults in
            defaults.set(1_791_158_400.0, forKey: "stamp.serverSince")
            XCTAssertEqual(MemberStamp.restoredSince(settings: defaults)?.timeIntervalSince1970, 1_791_158_400)
        }
    }

    func testArbitraryStoredServerValuesAreIgnored() {
        settings { defaults in
            XCTAssertNil(MemberStamp.restoredSince(settings: defaults))
            let values: [Any] = [0.0, -1.0, 1.0, Double.nan, Double.infinity,
                                 -Double.infinity, Double.greatestFiniteMagnitude,
                                 Date().timeIntervalSince1970 + 7 * 86_400,
                                 "yesterday", Data([0, 1]), ["since": 1], [1, 2], true]
            for value in values {
                defaults.set(value, forKey: "stamp.serverSince")
                XCTAssertNil(MemberStamp.restoredSince(settings: defaults), "Stored value: \(value)")
            }
        }
    }

    func testRestoredDateReplacesEarlierHistoryAndSurvivesReload() {
        settings { defaults in
            let old = Date(timeIntervalSince1970: 1_788_307_200)
            let restored = Date(timeIntervalSince1970: 1_791_158_400)
            defaults.set(old.timeIntervalSince1970, forKey: "stamp.since")
            let answer: [String: Any] = ["since": restored.timeIntervalSince1970, "sinceAuthoritative": true]
            XCTAssertEqual(MemberStamp.keepAuthoritativeSince(in: answer, settings: defaults), restored)
            XCTAssertEqual(defaults.double(forKey: "stamp.since"), restored.timeIntervalSince1970)
            // Sync may still deliver an older legacy value; initialization prefers the server cache.
            defaults.set(old.timeIntervalSince1970, forKey: "stamp.since")
            XCTAssertEqual(MemberStamp.restoredSince(settings: defaults), restored)
        }
    }

    func testLaterServerCorrectionCanReplaceAnEarlierServerDate() {
        settings { defaults in
            let early = Date(timeIntervalSince1970: 1_788_307_200)
            let later = Date(timeIntervalSince1970: 1_791_158_400)
            _ = MemberStamp.keepAuthoritativeSince(in: ["since": early.timeIntervalSince1970, "sinceAuthoritative": true], settings: defaults)
            _ = MemberStamp.keepAuthoritativeSince(in: ["since": later.timeIntervalSince1970, "sinceAuthoritative": true], settings: defaults)
            XCTAssertEqual(MemberStamp.restoredSince(settings: defaults), later)
        }
    }

    func testUnmarkedAndInvalidResponsesDoNotReplaceTheCache() {
        settings { defaults in
            let kept = Date(timeIntervalSince1970: 1_791_158_400)
            _ = MemberStamp.keepAuthoritativeSince(in: ["since": kept.timeIntervalSince1970, "sinceAuthoritative": true], settings: defaults)
            let answers: [[String: Any]] = [
                ["since": 1_788_307_200.0],
                ["since": 1_788_307_200.0, "sinceAuthoritative": false],
                ["since": 1.0, "sinceAuthoritative": true],
                ["since": "yesterday", "sinceAuthoritative": true],
                ["since": Double.infinity, "sinceAuthoritative": true]
            ]
            for answer in answers {
                XCTAssertNil(MemberStamp.keepAuthoritativeSince(in: answer, settings: defaults))
                XCTAssertEqual(MemberStamp.restoredSince(settings: defaults), kept)
                XCTAssertEqual(defaults.double(forKey: "stamp.since"), kept.timeIntervalSince1970)
            }
        }
    }
}
