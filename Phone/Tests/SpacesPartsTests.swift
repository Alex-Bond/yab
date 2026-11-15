import XCTest
import UIKit
@testable import YabPhone

/// The pieces the spaces kept from the column: the pin grid's rules, the
/// springs and the capsule's math, and what a held tab's menu changes.
@MainActor
final class PinGridTests: XCTestCase {
    func testPinsFillTheWidthInEvenRows() {
        func grid(_ n: Int, open: Bool = false) -> PinGrid {
            PinGrid(pins: (0..<n).map { Tab(id: "p\($0)", title: "\($0)", site: "\($0)", icon: "github") }, open: open, width: 362)
        }
        XCTAssertTrue(grid(0).cells.isEmpty)
        XCTAssertEqual(grid(0).height, 0)
        XCTAssertEqual(grid(1).cells.first?.frame.width, 362)
        XCTAssertEqual([grid(2).columns, grid(4).columns, grid(5).columns], [2, 4, 5])
        XCTAssertEqual(grid(8).rows, 2)
        XCTAssertEqual(grid(8).columns, 4)
        XCTAssertEqual(grid(15).rows, 3)
        XCTAssertEqual(grid(15).cells.count, 15)
        // Past three rows the 15th cell says how many more.
        XCTAssertEqual(grid(16).cells.count, 15)
        XCTAssertEqual(grid(16).cells.last?.kind, .more(2))
        XCTAssertEqual(grid(17).cells.last?.kind, .more(3))
        XCTAssertEqual(grid(40).cells.last?.kind, .more(26))
        // Open: all of them, rows as even as they can be.
        XCTAssertEqual(grid(17, open: true).rows, 4)
        XCTAssertEqual(grid(17, open: true).columns, 5)
        XCTAssertEqual(grid(16, open: true).columns, 4)
        XCTAssertEqual(grid(40, open: true).rows, 8)
        XCTAssertEqual(grid(8).height, 52 * 2 + 8)
    }
}

/// The spaces' motion and math are the prototype's.
@MainActor
final class SpacesMotionTests: XCTestCase {
    func testRubberBand() {
        XCTAssertEqual(ColumnMath.rubber(0, 70), 0)
        XCTAssertEqual(ColumnMath.rubber(70, 70), (1 - 1 / 1.55) * 70, accuracy: 0.0001)
        XCTAssertEqual(ColumnMath.rubber(-70, 70), -(1 - 1 / 1.55) * 70, accuracy: 0.0001)
        XCTAssertLessThan(ColumnMath.rubber(10_000, 60), 60)
    }

    func testSpringsCarryTheirNumbers() {
        XCTAssertEqual(Motion.space.response, 0.2)
        XCTAssertEqual(Motion.tabSwipe.response, 0.3)
        XCTAssertNil(Motion.columnRows.response)
    }

    func testASpringJumpsWhenMotionIsOff() {
        let was = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = was }
        var seen: [CGFloat] = []
        var done = false
        let spring = SpringValue(0) { seen.append($0) }
        spring.animate(to: 352, .spacesMorph, velocity: -900) { done = $0 }
        XCTAssertEqual(spring.value, 352)
        XCTAssertTrue(done)
        XCTAssertEqual(seen.last, 352)
        XCTAssertFalse(spring.isMoving)
    }

    func testASpringSettlesWithoutOvershoot() async {
        let was = Motion.disabled
        Motion.disabled = false
        defer { Motion.disabled = was }
        guard !Motion.reduced else { return }
        var highest: CGFloat = 0
        let spring = SpringValue(900) { highest = max(highest, 900 - $0) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            spring.animate(to: 352, .chatGrow) { _ in done.resume() }
        }
        XCTAssertEqual(spring.value, 352)
        XCTAssertLessThanOrEqual(highest, 900 - 352 + 0.05, "a critically damped spring never passes its target")
    }

    func testTheCapsuleLensFollowsThePosition() {
        let track = CapsuleTrack(names: ["Personal", "Work", "Lisbon"])
        XCTAssertEqual(track.widths.count, 3, "no New Space cell after the last name")
        XCTAssertEqual(track.at(1).center, track.centers[1])
        XCTAssertEqual(track.at(1).width, track.widths[1])
        let between = track.at(1.5)
        XCTAssertEqual(between.center, (track.centers[1] + track.centers[2]) / 2, accuracy: 0.001)
        XCTAssertEqual(track.at(2).center, track.centers[2])
    }
}

/// What a held tab's menu on the spaces changes in the stores.
@MainActor
final class TabActionTests: XCTestCase {
    func testCopyKeepsTheOriginalNavigationURL() throws {
        let app = AppModel(world: try World.load(named: "mira"), fixturesEnabled: false)
        app.surfaces.toastsStay = true
        let pasteboard = UIPasteboard.general
        let before = pasteboard.items
        defer { pasteboard.items = before }
        for original in ["http://www.example.com:8765/A?q=Two#three", "https://www.example.com/a%2Fb?case=UPPER#section"] {
            let tab = PageFixtures.liveTab(for: try XCTUnwrap(URL(string: original)))
            app.copyLink(of: tab)
            XCTAssertEqual(pasteboard.url?.absoluteString, original, "Copy Link is the URL, including its scheme, host and escaping")
            XCTAssertEqual(app.link(of: tab)?.absoluteString, original, "the share sheet uses the same exact link")
        }
        app.sync.attach(app, setup: nil)
        app.sync.openOnMac(try XCTUnwrap(app.browser.tab))
        XCTAssertEqual(app.surfaces.toast?.text, SyncBridge.QuestionFailure.notJoined.localizedDescription)
        XCTAssertNil(app.sync.engine, "an unjoined browser creates no remote open request")
    }

    func testCarryingReordersOnlyItsOwnList() throws {
        let store = BrowserStore(world: try World.load(named: "mira"))
        store.move("work-hn", before: "work-lumen")
        XCTAssertEqual(store.space.today.map(\.id), ["work-gh-pr", "work-tern-local", "work-hn", "work-lumen", "work-linear-method"])
        store.move("work-hn", before: nil)
        XCTAssertEqual(store.space.today.last?.id, "work-hn")
        store.move("work-onb-funnel", before: "work-figma-onb")
        XCTAssertEqual(store.space.folders.first?.tabs.map(\.id), ["work-onb-funnel", "work-figma-onb", "work-onb-spec"])
        store.move("work-ledger", before: "work-launch-notes")
        XCTAssertEqual(store.space.kept.map(\.id), ["folder:work-onboarding", "tab:work-ledger", "tab:work-launch-notes"])
        // Never into another list.
        store.move("work-hn", before: "work-ledger")
        XCTAssertEqual(store.space.today.last?.id, "work-hn")
    }

    func testClosingTheTabInFrontBringsTodaysFirst() async throws {
        let was = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = was }
        let app = AppModel(world: try World.load(named: "mira"))
        app.browser.select("work-lumen")
        ColumnState.of(app).close("work-lumen")
        XCTAssertNil(app.browser.tab("work-lumen"))
        XCTAssertEqual(app.browser.tab?.id, "work-hn")
    }

    func testKeepAndUnkeepMoveRowsAcrossTheLine() throws {
        let was = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = was }
        let app = AppModel(world: try World.load(named: "mira"))
        let state = ColumnState.of(app)
        state.keep("work-hn")
        XCTAssertEqual(app.browser.space.kept.last?.id, "tab:work-hn")
        state.unkeep("work-hn")
        XCTAssertEqual(app.browser.space.today.first?.id, "work-hn")
        state.move("work-hn", to: "personal")
        XCTAssertEqual(app.browser.space("personal")?.today.first?.id, "work-hn")
    }

    func testMovingTheTabInFrontLeavesTodaysFirstInFront() throws {
        let store = BrowserStore(world: try World.load(named: "mira"))
        store.select("work-ledger")
        store.move("work-ledger", to: "lisbon")
        XCTAssertEqual(store.space("work")?.current, "work-hn", "as Close: today's first, as the prototype's tabMenuPick")
        XCTAssertEqual(store.space("lisbon")?.today.first?.id, "work-ledger")
        // With nothing in today's, the first row; with no rows, the first pin.
        let pins = BrowserStore(world: try World.load(named: "mira"))
        for id in pins.space("lisbon")?.rows.map(\.id) ?? [] where id != "lisbon-wiki" { pins.move(id, to: "work") }
        pins.select("lisbon-wiki")
        pins.move("lisbon-wiki", to: "work")
        XCTAssertEqual(pins.space("lisbon")?.current, pins.space("lisbon")?.visiblePins.first?.id)
        XCTAssertNotNil(pins.space("lisbon")?.current, "no space is left without a tab in front")
    }

    func testClearProtectsPagesWhoseOwnershipAndSafetyAreUnknown() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.browser.select("work-tern-local")
        let gh = try XCTUnwrap(app.browser.tab("work-gh-pr"))
        app.pages.warm(gh)
        let before = app.browser.space
        let gone = await app.tabClear.clear(in: "work")
        XCTAssertEqual(gone, 0)
        XCTAssertEqual(app.browser.space, before)
        XCTAssertTrue(app.pages.isLive("work-gh-pr"), "warming a fixture is not a proof of safe ownership")
    }

    func testClearKeepsTheTabInFrontAndDoesNotPromiseUnverifiedMacDeletion() async throws {
        let app = AppModel(world: try World.load(named: "mira"))
        app.surfaces.toastsStay = true
        app.browser.select("work-tern-local")
        let before = app.browser.space.today
        let gone = await app.tabClear.clear(in: "work")
        XCTAssertEqual(gone, 0)
        XCTAssertEqual(app.browser.tab?.id, "work-tern-local")
        XCTAssertEqual(app.browser.space.today, before)
        XCTAssertEqual(app.surfaces.toast?.text, "No tabs cleared · active, shared or unverified pages stay")
    }
}
