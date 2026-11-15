import XCTest
@testable import Fast

@MainActor
final class AgentMacAccessTests: XCTestCase {
    func testFreshTaskNeedsAccessBeforeGettingMacTools() {
        for mode in AgentAsking.allCases {
            let automatic = Agents.macAccess(nil, previous: false, mode: mode)
            XCTAssertFalse(automatic.full, "\(mode) must start browser-only")
            XCTAssertFalse(automatic.ask, "\(mode) must not ask before Mac access is needed")

            let explicit = Agents.macAccess("full", previous: false, mode: mode)
            XCTAssertEqual(explicit.full, mode == .bypass)
            XCTAssertEqual(explicit.ask, mode != .bypass)

            let removed = Agents.macAccess("code", previous: false, mode: mode)
            XCTAssertFalse(removed.full)
            XCTAssertFalse(removed.ask)
            let restricted = Agents.macAccess("browser", previous: true, mode: mode)
            XCTAssertFalse(restricted.full)
            XCTAssertFalse(restricted.ask)
        }
    }

    func testResumeKeepsGrantOnlyForSameTask() {
        for mode in AgentAsking.allCases {
            let resumed = Agents.macAccess(nil, previous: true, mode: mode)
            XCTAssertTrue(resumed.full)
            XCTAssertFalse(resumed.ask)
        }
    }

    func testMacAccessCardRequiresDangerConfirmation() {
        let card = AgentPermit(kind: .computer, session: "task", detail: "Read a project file")
        XCTAssertEqual(card.question, "Let this task use your Mac?")
        XCTAssertEqual(card.answers.map(\.title), ["Allow Mac access"])
        XCTAssertTrue(card.weighty)
        XCTAssertNil(card.ruleLabel)
    }

    func testExternalAgentKeepsItsOwnMacPermissions() {
        let external = Agents.Session(id: "external", cli: "external", name: "Codex", prompt: "", state: .attached)
        XCTAssertTrue(external.full)
    }

    func testStoppedTaskCannotGainMacAccessFromLateApproval() {
        let agents = Agents()
        let stopped = Agents.Session(id: "stopped", cli: "codex", name: "Codex", prompt: "", state: .stopped)
        stopped.full = false
        stopped.awaitingMacAccess = true
        agents.allowMacAccess(stopped)
        XCTAssertFalse(stopped.full)
        XCTAssertEqual(stopped.state, .stopped)
    }
}
