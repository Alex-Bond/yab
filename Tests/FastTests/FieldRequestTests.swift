import XCTest
@testable import Fast

@MainActor
final class FieldRequestTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Tuesday, October 13, 2026, 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_892_800)

    private func parts(_ date: Date?) -> DateComponents? {
        date.map { calendar.dateComponents([.weekday, .day, .hour, .minute], from: $0) }
    }

    func testWeekdayAtAnHourInWorkingTimeIsTheAfternoon() {
        let found = parts(RequestReader.when("meeting with caleb thursday at 3", now: now, calendar: calendar))
        XCTAssertEqual(found?.weekday, 5)
        XCTAssertEqual(found?.day, 15)
        XCTAssertEqual(found?.hour, 15)
        XCTAssertEqual(found?.minute, 0)
    }

    func testTomorrowWithMinutes() {
        let found = parts(RequestReader.when("call with hugo tomorrow at 10:30", now: now, calendar: calendar))
        XCTAssertEqual(found?.day, 14)
        XCTAssertEqual(found?.hour, 10)
        XCTAssertEqual(found?.minute, 30)
    }

    func testMorningSaidAsAm() {
        let found = parts(RequestReader.when("sync with anna friday 7am", now: now, calendar: calendar))
        XCTAssertEqual(found?.weekday, 6)
        XCTAssertEqual(found?.hour, 7)
    }

    func testNoDayNoTime() {
        XCTAssertNil(RequestReader.when("meeting with caleb about pricing", now: now, calendar: calendar))
    }

    func testSiteNameFromHost() {
        XCTAssertEqual(Address.siteName("www.amazon.com"), "Amazon")
        XCTAssertEqual(Address.siteName("wd5.myworkday.com"), "Myworkday")
    }

    func testJevIsAskedThreeQuestions() {
        let caleb = MailDesk.Contact(name: "Caleb Demir", address: "caleb@plexum.io", threads: 41)
        let body = RequestModel.body("call with caleb", model: "typesafe/jev-1.13", people: [caleb], hosts: ["www.amazon.com"])
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.13")
        XCTAssertEqual(body["state"] as? String, "call with caleb")
        let questions = body["questions"] as? [String: Any]
        XCTAssertEqual(Set(questions?.keys.map { $0 } ?? []), ["kind", "person", "site"])
        let person = questions?["person"] as? [String: Any]
        XCTAssertEqual(person?["type"] as? String, "choice")
        let people = person?["criteria"] as? [String: String]
        XCTAssertEqual(people?["0"], "Caleb Demir, 41 mail threads")
        XCTAssertFalse(people?.keys.contains { $0.contains("@") } ?? true, "no address goes to Jev")
        XCTAssertEqual(((questions?["site"] as? [String: Any])?["criteria"] as? [String: String])?["0"], "Amazon (www.amazon.com)")
    }

    func testJevsPicksAreRead() {
        let reply: [String: Any] = [
            "model": "typesafe/jev-1.13-20260917",
            "answers": [
                "kind": ["type": "choice", "choice": "meeting", "confidence": 0.97],
                "person": ["type": "choice", "choice": "0"],
                "site": ["type": "choice", "choice": "none"],
            ],
        ]
        let picked = RequestModel.picked(reply)
        XCTAssertEqual(picked?.kind, "meeting")
        XCTAssertEqual(picked?.person, "0")
        XCTAssertNil(picked?.host)
        XCTAssertEqual(picked?.confidence, 0.97)
        XCTAssertNil(RequestModel.picked(["answers": [:]]))
    }

    func testTokensAreTheWordsOnce() {
        XCTAssertEqual(RequestModel.tokens("cancel my plan on clerk"), ["cancel", "plan", "clerk"])
        XCTAssertEqual(RequestModel.tokens("Clerk clerk"), ["clerk"])
    }

    /// Reading the Field says when its reader can't read and only plain
    /// words are.
    @MainActor
    func testReadingTheFieldSaysWhenItCantRead() {
        let system = FieldReader.system.detail
        if let why = FormModel.why {
            XCTAssertTrue(system.hasPrefix(why), system)
            XCTAssertTrue(system.contains("only plain words"), system)
        } else {
            XCTAssertFalse(system.contains("only plain words"), system)
        }
        XCTAssertEqual(FieldReader.jev.detail.contains("Needs your OpenRouter key"), OpenRouterKey.read() == nil)
        // The words never carry the key itself.
        XCTAssertFalse(FieldReader.jev.detail.contains("sk-or-v1"))
    }

    /// The Mac's model names someone only when the words do.
    func testTheMacsModelKeepsOnlyNamedPeopleAndSites() {
        XCTAssertTrue(SystemReader.named("Taro Fukuyama", in: "who is taro"))
        XCTAssertTrue(SystemReader.named("Elizabeth Yin", in: "call with eliza"))
        XCTAssertTrue(SystemReader.named("www.figma.com", in: "close figma"))
        XCTAssertFalse(SystemReader.named("DoorDash", in: "close all github tabs"))
        XCTAssertFalse(SystemReader.named("Hustle Fund Portfolio Founders", in: "elizabeth's mail about the round"))
        XCTAssertTrue(SystemReader.named("Density: Compact", in: "compact sidebar"))
        XCTAssertTrue(SystemReader.named("www.youtube.com", in: "close the yutub tabs"))
        XCTAssertGreaterThan(SystemReader.matches("Sidebar side: right", in: "sidebar on the right"),
                             SystemReader.matches("Developer Tools open: right", in: "sidebar on the right"))
    }

    /// A role the words say finds its people, typed right or wrong:
    /// "my lawers mail" names nobody, but asks for the lawyer.
    @MainActor
    func testRolesAreReadAndTyposMended() {
        XCTAssertEqual(FieldRoles.mended(["lawers"])["lawers"], "lawyers")
        XCTAssertNil(FieldRoles.mended(["snooze"])["snooze"])
        XCTAssertEqual(FieldRoles.role(in: ["lawyers"])?.0.name, "lawyer")
        XCTAssertEqual(FieldRoles.role(in: ["accountant"])?.0.name, "accountant")
        XCTAssertNil(FieldRoles.role(in: ["lawers"]), "only once mended")
        XCTAssertNil(FieldRoles.role(in: ["deel", "contract"]))
        XCTAssertEqual(Candidates.content("my lawers mail"), ["lawers"])
        let lawyer = FieldRoles.all[0]
        for firm in ["lamato@goodwinlaw.com", "boris@lisaesq.com", "td@bayimmigrationlaw.com", "a@legalzoom.com", "b@smith-law.co.uk"] {
            XCTAssertTrue(FieldRoles.marked(firm, lawyer), firm)
        }
        for other in ["alex@clawconfigkit.com", "heyganesh@thesquirrel.tech", "no-reply-esq@slack.com", "law@gmail.com"] {
            XCTAssertFalse(FieldRoles.marked(other, lawyer), other)
        }
    }
}
